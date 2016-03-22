{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

-- | Contains the types and functions necessary for sending an email via SendGrid.
module Network.API.SendGrid.SendEmail where

import Control.Lens (makeLenses, Lens', lens, (^?), (^.))
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Reader (runReaderT)
import Control.Monad.Reader.Class (MonadReader, ask)
import Data.Aeson hiding (Result(..))
import Data.Aeson.Lens (_JSON)
import Data.ByteString as BS (ByteString)
import Data.ByteString.Lazy as BSL (toStrict)
import qualified Data.DList as D
import Data.HashMap.Strict as H (empty)
import Data.List (foldl')
import Data.List.NonEmpty (NonEmpty(..))
import qualified Data.List.NonEmpty as NE
import Data.Maybe (maybeToList, fromMaybe)
import Data.Monoid ((<>))
import Data.Tagged (Tagged, unTagged)
import Data.Text as T (Text, pack, unpack)
import Data.These (These(..))
import Data.Time (UTCTime(..), defaultTimeLocale, formatTime)
import GHC.Generics (Generic)
import Network.HTTP.Client (RequestBody(RequestBodyBS))
import Network.HTTP.Client.MultipartFormData (partFileRequestBody)
import Network.HTTP.Types.Header (Header)
import Network.Wreq (responseBody, partBS, partText, Part, responseStatus)
import Network.Wreq.Session (postWith, Session)
import Network.Wreq.Types (Postable(..))
import Text.Blaze.Html (Html)
import Text.Blaze.Html.Renderer.Utf8 (renderHtml)
import Text.Email.Validate as E (EmailAddress, toByteString)

import Network.API.SendGrid.Core

sendEmailEndPoint :: Text
sendEmailEndPoint = baseSendGridUrl <> "mail.send.json"

-- * Types

-- | Type for attached files.
-- Consists of content and the name that content will appear under in the email.
data File
 = File
  { _fileName    :: Text
  , _fileContent :: BS.ByteString
  } deriving (Eq, Read, Show, Generic)
makeLenses ''File

-- | Type for SendGrid's content field.
-- Consists of a file and name by which you can refer to that file.
data Content
  = Content
  { _file        :: File
  , _contentId   :: Text
  } deriving (Eq, Read, Show, Generic)
makeLenses ''Content

data UnsubscribeGroupId
data TemplateId

-- | The configuration type for your email sending request.
data SendEmail cat
 = SendEmail
  { _recipients           :: Either (NonEmpty NamedEmail) (NonEmpty EmailAddress)
  , _replyTo              :: Maybe EmailAddress
  , _cc                   :: Maybe (Either (NonEmpty NamedEmail) (NonEmpty EmailAddress))
  , _bcc                  :: Maybe (Either (NonEmpty NamedEmail) (NonEmpty EmailAddress))
  , _sender               :: EmailAddress
  , _senderName           :: Maybe Text
  , _subject              :: Text
  , _body                 :: These Html Text
  , _date                 :: Maybe UTCTime
  , _files                :: [File] -- ^ Don't duplicate files from @_content@ here. @_content@ already handles the file attaching.
  , _content              :: [Content]
  , _headers              :: [Header]
  , _categories           :: [cat]
    -- ^ Specify the categories with which to label the email.
    -- Should be a type that supports @ToJSON@.
    -- e.g. @Text@ or your own enum like @data Category = Transactional | Marketing@
  , _templateId           :: Maybe (Tagged TemplateId Text) -- ^ A typeful way to specify this subpart of the SendGrid's SMTP param
  , _inlineUnsubscribe    :: Maybe (Tagged UnsubscribeGroupId Int)
  , _prefPageUnsubscribes :: [Tagged UnsubscribeGroupId Int]
  , _smtp                 :: Maybe Value
    -- ^ Escape hatch for other uses of SendGrid's SMTP param.
    -- If the keys you define here don't overlap with @categories@ or @templateId@, everything will be merged sensibly.
    -- If they do overlap, the @_categories@ and @_templateId@ take precedence.
  }
-- Can't derive @Eq@ or @Show@ because of @Html@
makeLenses ''SendEmail

-- | Makes using @cc@ and @bcc@ friendlier. e.g.
--
-- @email & bcc . plainEmails .~ [ email1, email2 ]@
plainEmails :: Lens' (Maybe (Either (NonEmpty NamedEmail) (NonEmpty EmailAddress))) [EmailAddress]
plainEmails =
  lens getter setter
    where
      getter (Just (Right xs)) = NE.toList xs
      getter _ = []
      setter _ [] = Nothing
      setter _ (x : xs) = Just (Right $ x :| xs)

-- | Makes using @cc@ and @bcc@ friendlier. e.g.
--
-- @email & bcc . namedEmails .~ [ namedEmail1, namedEmail2 ]@
namedEmails :: Lens' (Maybe (Either (NonEmpty NamedEmail) (NonEmpty EmailAddress))) [NamedEmail]
namedEmails =
  lens getter setter
    where
      getter (Just (Left xs)) = NE.toList xs
      getter _ = []
      setter _ [] = Nothing
      setter _ (x : xs) = Just (Left $ x :| xs)

-- * Constructors

-- | Helper constructor to make the minimal @SendEmail@,
-- one with everything possible set to @Nothing@ or @[]@.
mkSendEmail :: Either (NonEmpty NamedEmail) (NonEmpty EmailAddress) -> Text -> These Html Text -> EmailAddress -> SendEmail cat
mkSendEmail to subject' body' from
  = SendEmail
  { _recipients           = to
  , _replyTo              = Nothing
  , _cc                   = Nothing
  , _bcc                  = Nothing
  , _sender               = from
  , _senderName           = Nothing
  , _subject              = subject'
  , _body                 = body'
  , _date                 = Nothing
  , _files                = []
  , _content              = []
  , _headers              = []
  , _categories           = []
  , _templateId           = Nothing
  , _inlineUnsubscribe    = Nothing
  , _prefPageUnsubscribes = []
  , _smtp                 = Nothing
  }

-- | Convenience constructor to make an email intended for a single recipient.
mkSingleRecipEmail :: EmailAddress -> Text -> These Html Text -> EmailAddress -> SendEmail cat
mkSingleRecipEmail to = mkSendEmail (Right $ pure to)

-- * Serializing @SendEmail@ for SendGrid

instance (ToJSON cat) => Postable (SendEmail cat) where
  postPayload = postPayload . sendEmailToParts

sendEmailToParts :: (ToJSON cat) => SendEmail cat -> [Part]
sendEmailToParts SendEmail{..} =
  D.toList $ foldMap D.fromList
  [ toParts
  , [subjectPart]
  , bodyParts
  , [fromPart]
  , ccParts
  , bccParts
  , fromNamePart
  , replyToPart
  , datePart
  , headerPart
  , fileParts
  , contentParts
  , smtpPart
  ]
    where
      fileToPart File{..} = partFileRequestBody ("files[" <> _fileName  <> "]") (T.unpack _fileName) (RequestBodyBS _fileContent)
      contentParts = foldMap contentToParts _content
        where
          contentToParts (Content file'@File{..} cId) =
            [fileToPart file', partText ("content[" <> _fileName <> "]") cId]
      fileParts = fileToPart <$> _files
      toParts = emailsToParts "to[]" "toname[]" _recipients
      fromPart = partBS "from" $ E.toByteString _sender
      ccParts = maybe [] (emailsToParts "cc[]" "ccname[]") _cc
      bccParts = maybe [] (emailsToParts "bcc[]" "bccname[]") _bcc
      fromNamePart = maybeToList $ partText "fromname" <$> _senderName
      replyToPart = maybeToList $ partBS "replyto" . E.toByteString <$> _replyTo
      datePart = maybeToList $ partText "date" . T.pack . formatTime defaultTimeLocale sendGridDateFormat <$> _date
      subjectPart = partText "subject" _subject
      smtpPart =
        maybe [] (pure . partBS "x-smtpapi" . BSL.toStrict . encode) $
        smtpValue _templateId _categories _inlineUnsubscribe _prefPageUnsubscribes _smtp
      headerPart =
        case _headers of
          [] -> []
          headers' -> [partBS "headers" . headersToBS $ headers']
      bodyParts =
        case _body of
          This html -> [partBS "html" . BSL.toStrict $ renderHtml html]
          That text -> [partText "text" text]
          These html text -> [partBS "html" . BSL.toStrict $ renderHtml html, partText "text" text]

emailsToParts :: Text -> Text -> Either (NonEmpty NamedEmail) (NonEmpty EmailAddress) -> [Part]
emailsToParts emailKey nameKey (Left namedEmails') =
  flip foldMap namedEmails'
     (\NamedEmail{..} ->
       [ partBS emailKey $ E.toByteString _email
       , partText nameKey _name
       ])
emailsToParts emailKey _ (Right emails) =
  partBS emailKey . E.toByteString <$> NE.toList emails

smtpValue
  :: (ToJSON cat)
  => Maybe (Tagged TemplateId Text)
  -> [cat]
  -> Maybe (Tagged UnsubscribeGroupId Int)
  -> [Tagged UnsubscribeGroupId Int]
  -> Maybe Value
  -> Maybe Value
smtpValue templateId' categories' inlineUnsubscribe' prefPageUnsubscribes' custom =
  if merged == mempty'
  then Nothing
  else Just merged
  where
    merged =
      foldl'
        mergeObjects
        mempty'
        [ maybe mempty' (templateIdToSmtpHeader . unTagged) templateId'
        , maybe mempty' categoriesToSmtpHeader $ NE.nonEmpty categories'
        , maybe mempty' (inlineUnsubscribeToSmtpHeader . unTagged) inlineUnsubscribe'
        , maybe mempty' prefPageUnsubscribesToSmtpHeader $ NE.nonEmpty prefPageUnsubscribes'
        , fromMaybe mempty' custom
        ]
    mempty' = Object H.empty
    inlineUnsubscribeToSmtpHeader iu =
      object
        [ "asm_group_id" .= iu
        ]
    prefPageUnsubscribesToSmtpHeader us =
      object
        [ "asm_groups_to_display" .= toJSON (unTagged <$> NE.toList us)
        ]
    categoriesToSmtpHeader cs =
      object
        [ "category" .= toJSON (NE.toList cs)
        ]
    templateIdToSmtpHeader tId =
      object
        [ "filters" .=
          object
            [ "templates" .=
              object
                [ "settings" .=
                  object
                    [ "template_id" .= tId
                    , "enable" .= (1 :: Int)
                    ]
                ]
            ]
        ]


-- * Sending email

-- | Simple function for sending email via SendGrid.
sendEmailSimple :: (ToJSON cat, MonadIO m) => Tagged ApiKey Text -> Session -> SendEmail cat -> m Result
sendEmailSimple key session e = runReaderT (sendEmail e) (key, session)

sendEmail :: (ToJSON cat) => (MonadReader (Tagged ApiKey Text, Session) m, MonadIO m) => SendEmail cat -> m Result
sendEmail msg = do
  (key, session) <- ask
  liftIO $ handleResponse <$> postWith (authOptions key) session (T.unpack sendEmailEndPoint) msg
  where
    handleResponse rsp = maybe (ParseError rsp) (elaborate rsp) $ rsp ^? responseBody . _JSON
    elaborate _ JSuccess = Success
    elaborate rsp (JSendGridErrors es) = SendGridErrors (rsp ^. responseStatus) es
