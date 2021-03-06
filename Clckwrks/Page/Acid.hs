{-# LANGUAGE DeriveDataTypeable, TemplateHaskell, TypeFamilies, RecordWildCards, OverloadedStrings, QuasiQuotes #-}
module Clckwrks.Page.Acid
    ( module Clckwrks.Page.Types
      -- * state
    , PageState
    , initialPageState
      -- * events
    , NewPage(..)
    , PageById(..)
    , GetPageTitle(..)
    , IsPublishedPage(..)
    , PagesSummary(..)
    , UpdatePage(..)
    , AllPosts(..)
    , AllPublishedPages(..)
    , GetFeedConfig(..)
    , SetFeedConfig(..)
    , GetBlogTitle(..)
    , GetOldUACCT(..)
    , ClearOldUACCT(..)
    ) where

import Clckwrks             (UserId(..))
import Clckwrks.Page.Types  (Markup(..), PublishStatus(..), PreProcessor(..), PageId(..), PageKind(..), Page(..), Pages(..), FeedConfig(..), Slug(..), initialFeedConfig, slugify)
import Clckwrks.Page.Verbatim (verbatimText)
import Clckwrks.Types       (Trust(..))
import Clckwrks.Monad       (ThemeStyleId(..))
import Control.Applicative  ((<$>))
import Control.Monad.Reader (ask)
import Control.Monad.State  (get, modify, put)
import Control.Monad.Trans  (liftIO)
import Data.Acid            (AcidState, Query, Update, makeAcidic)
import Data.Data            (Data, Typeable)
import Data.IxSet           (Indexable, IxSet, (@=), Proxy(..), empty, fromList, getOne, ixSet, ixFun, insert, toList, toDescList, updateIx)
import Data.Maybe           (fromJust)
import Data.SafeCopy        (Migrate(..), base, deriveSafeCopy, extension)
import Data.String          (fromString)
import Data.Text            (Text)
import Data.Time.Clock      (UTCTime, getCurrentTime)
import Data.Time.Clock.POSIX(posixSecondsToUTCTime)
import qualified Data.Text  as Text
import           Data.UUID  (UUID)
import qualified Data.UUID  as UUID
import HSP.Google.Analytics (UACCT)

data PageState_001  = PageState_001
    { nextPageId_001 :: PageId
    , pages_001      :: IxSet Page
    }
    deriving (Eq, Read, Show, Data, Typeable)
$(deriveSafeCopy 1 'base ''PageState_001)

data PageState_002  = PageState_002
    { nextPageId_002 :: PageId
    , pages_002      :: IxSet Page
    , feedConfig_002 :: FeedConfig
    }
    deriving (Eq, Read, Show, Data, Typeable)
$(deriveSafeCopy 2 'extension ''PageState_002)

instance Migrate PageState_002 where
    type MigrateFrom PageState_002 = PageState_001
    migrate (PageState_001 npi pgs) =
        PageState_002 npi pgs (FeedConfig { feedUUID       = fromJust $ UUID.fromString "fa6cf090-84d7-11e1-8001-0021cc712949"
                                          , feedTitle      = fromString "Untitled Feed"
                                          , feedLink       = fromString ""
                                          , feedAuthorName = fromString "Anonymous"
                                          })

data PageState  = PageState
    { nextPageId :: PageId
    , pages      :: IxSet Page
    , feedConfig :: FeedConfig
    , uacct      :: Maybe UACCT
    }
    deriving (Eq, Read, Show, Data, Typeable)
$(deriveSafeCopy 3 'extension ''PageState)

instance Migrate PageState where
    type MigrateFrom PageState = PageState_002
    migrate (PageState_002 npi pgs fc) =
        PageState npi pgs fc Nothing

initialPageMarkup :: Text
initialPageMarkup = [verbatimText|Congratulations! You are now running clckwrks! There are a few more steps you will want to take now.

Create an Account
-----------------

Go [here](/authenticate/login) and create an account for yourself.

Give yourself Administrator permissions
-------------------------------

After you create an account you will want to give yourself `Administrator` privileges. This can be done using the `clckwrks-cli` tool. *While the server is running* invoke `clckwrks-cli` and point it to the socket file:

    $ clckwrks-cli _state/profileData_socket

that should start an interactive session. If the server is running as `root`, then you may need to add a `sudo` in front.

Assuming you are `UserId 1` you can now give yourself admin access:

    % user add-role 1 Administrator

You can run `help` for a list of other commands. Type `quit` to exit.

Explore the Admin console
-------------------------

Now you can explore the [Admin Console](/clck/admin/console).

|]

initialPageState :: IO PageState
initialPageState =
    do fc <- initialFeedConfig
       return $ PageState { nextPageId = PageId 2
                          , pages = fromList [ Page { pageId        = PageId 1
                                                    , pageAuthor    = UserId 1
                                                    , pageTitle     = "Welcome To clckwrks!"
                                                    , pageSlug      = Just $ slugify "Welcome to clckwrks"
                                                    , pageSrc       = Markup { preProcessors = [ Pandoc ]
                                                                             , trust         = Trusted
                                                                             , markup        = initialPageMarkup
                                                                             }
                                                    , pageExcerpt   = Nothing
                                                    , pageDate      = posixSecondsToUTCTime 1334089928
                                                    , pageUpdated   = posixSecondsToUTCTime 1334089928
                                                    , pageStatus    = Published
                                                    , pageKind      = PlainPage
                                                    , pageUUID      = fromJust $ UUID.fromString "c306fe3a-8346-11e1-8001-0021cc712949"
                                                    , pageThemeStyleId = ThemeStyleId 0
                                                    }
                                             ]
                          , feedConfig = fc
                          , uacct = Nothing
                          }

pageById :: PageId -> Query PageState (Maybe Page)
pageById pid =
    do pgs <- pages <$> ask
       return $ getOne $ pgs @= pid

-- | get the 'pageTitle' for 'PageId'
getPageTitle :: PageId -> Query PageState (Maybe (Text, Maybe Slug))
getPageTitle pid =
    do mPage <- pageById pid
       case mPage of
         Nothing     -> return $ Nothing
         (Just page) -> return $ Just (pageTitle page, pageSlug page)

-- | check if the 'PageId' corresponds to a published 'PageId'
isPublishedPage :: PageId -> Query PageState Bool
isPublishedPage pid =
    do pgs <- pages <$> ask
       case getOne $ pgs @= pid of
         Nothing     -> return False
         (Just page) -> return $ pageStatus page == Published

pagesSummary :: Query PageState [(PageId, Text, Maybe Slug, UTCTime, UserId, PublishStatus)]
pagesSummary =
    do pgs <- pages <$> ask
       return $ map (\page -> (pageId page, pageTitle page, pageSlug page, pageUpdated page, pageAuthor page, pageStatus page))
                  (toList pgs)

updatePage :: Page -> Update PageState (Maybe String)
updatePage page =
    do ps@PageState{..} <- get
       case getOne $ pages @= (pageId page) of
         Nothing  -> return $ Just $ "updatePage: Invalid PageId " ++ show (unPageId $ pageId page)
         (Just _) ->
             do put $ ps { pages = updateIx (pageId page) page pages }
                return Nothing

newPage :: PageKind -> UserId -> UUID -> UTCTime -> Update PageState Page
newPage pk uid uuid now =
    do ps@PageState{..} <- get
       let page = Page { pageId      = nextPageId
                       , pageAuthor  = uid
                       , pageTitle   = "Untitled"
                       , pageSlug    = Nothing
                       , pageSrc     = Markup { preProcessors = [ Pandoc ]
                                              , trust         = Trusted
                                              , markup        = Text.empty
                                              }
                       , pageExcerpt = Nothing
                       , pageDate    = now
                       , pageUpdated = now
                       , pageStatus  = Draft
                       , pageKind    = pk
                       , pageUUID    = uuid
                       , pageThemeStyleId = ThemeStyleId 0
                       }
       put $ ps { nextPageId = PageId $ succ $ unPageId nextPageId
                , pages      = insert page pages
                }
       return page

getFeedConfig :: Query PageState FeedConfig
getFeedConfig =
    do PageState{..} <- ask
       return feedConfig

getBlogTitle :: Query PageState Text
getBlogTitle =
    do PageState{..} <- ask
       return (feedTitle feedConfig)

setFeedConfig :: FeedConfig -> Update PageState ()
setFeedConfig fc =
    do ps <- get
       put $ ps { feedConfig = fc }

-- | get all 'Published' posts, sorted reverse cronological
allPosts :: Query PageState [Page]
allPosts =
    do pgs <- pages <$> ask
       return $ toDescList (Proxy :: Proxy UTCTime) (pgs @= Post @= Published)

-- | get all 'Published' pages, sorted in no particular order
allPublishedPages :: Query PageState [Page]
allPublishedPages =
    do pgs <- pages <$> ask
       return $ toList (pgs @= PlainPage @= Published)

-- | get the 'UACCT' for Google Analytics
--
-- DEPRECATED: moved to clckwrks / 'CoreState'
getOldUACCT :: Query PageState (Maybe UACCT)
getOldUACCT = uacct <$> ask

-- | zero out the UACCT code in 'PageState'. It belongs in 'CoreState'
-- now.
clearOldUACCT :: Update PageState ()
clearOldUACCT = modify $ \ps -> ps { uacct = Nothing }

$(makeAcidic ''PageState
  [ 'newPage
  , 'pageById
  , 'getPageTitle
  , 'isPublishedPage
  , 'pagesSummary
  , 'updatePage
  , 'allPosts
  , 'allPublishedPages
  , 'getFeedConfig
  , 'setFeedConfig
  , 'getBlogTitle
  , 'getOldUACCT
  , 'clearOldUACCT
  ])
