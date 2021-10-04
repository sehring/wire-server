{-# LANGUAGE RecordWildCards #-}

-- This file is part of the Wire Server implementation.
--
-- Copyright (C) 2020 Wire Swiss GmbH <opensource@wire.com>
--
-- This program is free software: you can redistribute it and/or modify it under
-- the terms of the GNU Affero General Public License as published by the Free
-- Software Foundation, either version 3 of the License, or (at your option) any
-- later version.
--
-- This program is distributed in the hope that it will be useful, but WITHOUT
-- ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
-- FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
-- details.
--
-- You should have received a copy of the GNU Affero General Public License along
-- with this program. If not, see <https://www.gnu.org/licenses/>.

module Galley.API.Util where

import Brig.Types (Relation (..))
import Brig.Types.Intra (ReAuthUser (..))
import Control.Arrow (Arrow (second), second)
import Control.Error (ExceptT, hoistEither, note)
import Control.Lens (set, view, (.~), (^.))
import Control.Monad.Catch
import Control.Monad.Except (runExceptT)
import Control.Monad.Extra (allM, anyM, eitherM)
import Data.ByteString.Conversion
import Data.Domain (Domain)
import Data.Id as Id
import Data.LegalHold (UserLegalHoldStatus (..), defUserLegalHoldStatus)
import Data.List.Extra (chunksOf, nubOrd)
import qualified Data.Map as Map
import Data.Misc (PlainTextPassword (..))
import Data.Qualified
import qualified Data.Set as Set
import Data.Tagged
import qualified Data.Text.Lazy as LT
import Data.Time
import Galley.API.Error
import Galley.App
import qualified Galley.Data as Data
import Galley.Data.LegalHold (isTeamLegalholdWhitelisted)
import Galley.Data.Services (BotMember, newBotMember)
import qualified Galley.Data.Types as DataTypes
import qualified Galley.External as External
import Galley.Intra.Push
import Galley.Intra.User
import Galley.Options (optSettings, setFeatureFlags, setFederationDomain)
import Galley.Types
import Galley.Types.Conversations.Members (localMemberToOther, remoteMemberToOther)
import Galley.Types.Conversations.Roles
import Galley.Types.Teams hiding (Event, MemberJoin, self)
import Galley.Types.UserList
import Imports
import Network.HTTP.Types
import Network.Wai
import Network.Wai.Predicate hiding (Error)
import Network.Wai.Utilities
import UnliftIO (concurrently)
import qualified Wire.API.Conversation as Public
import Wire.API.Conversation.Action (ConversationAction (..), conversationActionTag)
import Wire.API.ErrorDescription
import qualified Wire.API.Federation.API.Brig as FederatedBrig
import Wire.API.Federation.API.Galley as FederatedGalley
import Wire.API.Federation.Client (FederationClientFailure, FederatorClient, executeFederated)
import Wire.API.Federation.Error (federationErrorToWai)
import Wire.API.Federation.GRPC.Types (Component (..))
import qualified Wire.API.User as User

type JSON = Media "application" "json"

ensureAccessRole :: AccessRole -> [(UserId, Maybe TeamMember)] -> Galley ()
ensureAccessRole role users = case role of
  PrivateAccessRole -> throwErrorDescriptionType @ConvAccessDenied
  TeamAccessRole ->
    when (any (isNothing . snd) users) $
      throwErrorDescriptionType @NotATeamMember
  ActivatedAccessRole -> do
    activated <- lookupActivatedUsers $ map fst users
    when (length activated /= length users) $
      throwErrorDescriptionType @ConvAccessDenied
  NonActivatedAccessRole -> return ()

-- | Check that the given user is either part of the same team(s) as the other
-- users OR that there is a connection.
--
-- Team members are always considered connected, so we only check 'ensureConnected'
-- for non-team-members of the _given_ user
ensureConnectedOrSameTeam :: Qualified UserId -> [UserId] -> Galley ()
ensureConnectedOrSameTeam _ [] = pure ()
ensureConnectedOrSameTeam (Qualified u domain) uids = do
  -- FUTUREWORK(federation, #1262): handle remote users (can't be part of the same team, just check connections)
  localDomain <- viewFederationDomain
  when (localDomain == domain) $ do
    uTeams <- Data.userTeams u
    -- We collect all the relevant uids from same teams as the origin user
    sameTeamUids <- forM uTeams $ \team ->
      fmap (view userId) <$> Data.teamMembersLimited team uids
    -- Do not check connections for users that are on the same team
    ensureConnected u (uids \\ join sameTeamUids)

-- | Check that the user is connected to everybody else.
--
-- The connection has to be bidirectional (e.g. if A connects to B and later
-- B blocks A, the status of A-to-B is still 'Accepted' but it doesn't mean
-- that they are connected).
ensureConnected :: UserId -> [UserId] -> Galley ()
ensureConnected _ [] = pure ()
ensureConnected u localUserIds = do
  -- FUTUREWORK(federation, #1262): check remote connections
  ensureConnectedToLocals u localUserIds

ensureConnectedToLocals :: UserId -> [UserId] -> Galley ()
ensureConnectedToLocals _ [] = pure ()
ensureConnectedToLocals u uids = do
  (connsFrom, connsTo) <-
    getConnections [u] (Just uids) (Just Accepted)
      `concurrently` getConnections uids (Just [u]) (Just Accepted)
  unless (length connsFrom == length uids && length connsTo == length uids) $
    throwErrorDescriptionType @NotConnected

ensureReAuthorised :: UserId -> Maybe PlainTextPassword -> Galley ()
ensureReAuthorised u secret = do
  reAuthed <- reAuthUser u (ReAuthUser secret)
  unless reAuthed $
    throwM reAuthFailed

-- | Given a member in a conversation, check if the given action
-- is permitted. If the user does not have the given permission, throw
-- 'operationDenied'.
ensureActionAllowed :: IsConvMember mem => Action -> mem -> Galley ()
ensureActionAllowed action self = case isActionAllowed action (convMemberRole self) of
  Just True -> pure ()
  Just False -> throwErrorDescription (actionDenied action)
  -- Actually, this will "never" happen due to the
  -- fact that there can be no custom roles at the moment
  Nothing -> throwM (badRequest "Custom roles not supported")

-- | Comprehensive permission check, taking action-specific logic into account.
ensureConversationActionAllowed ::
  IsConvMember mem =>
  ConversationAction ->
  Data.Conversation ->
  mem ->
  Galley ()
ensureConversationActionAllowed action conv self = do
  loc <- qualifyLocal ()
  let tag = conversationActionTag (convMemberId loc self) action
  -- general action check
  ensureActionAllowed tag self
  -- check if it is a group conversation (except for rename actions)
  when (tag /= ModifyConversationName) $
    ensureGroupConvThrowing conv
  -- extra action-specific checks
  case action of
    ConversationActionAddMembers _ role -> ensureConvRoleNotElevated self role
    ConversationActionAccessUpdate target -> do
      -- 'PrivateAccessRole' is for self-conversations, 1:1 conversations and
      -- so on; users are not supposed to be able to make other conversations
      -- have 'PrivateAccessRole'
      when
        ( PrivateAccess `elem` Public.cupAccess target
            || PrivateAccessRole == Public.cupAccessRole target
        )
        $ throwErrorDescriptionType @InvalidTargetAccess
      -- Team conversations incur another round of checks
      case Data.convTeam conv of
        Just tid -> do
          -- Access mode change for managed conversation is not allowed
          tcv <- Data.teamConversation tid (Data.convId conv)
          when (maybe False (view managedConversation) tcv) $
            throwM invalidManagedConvOp
          -- Access mode change might result in members being removed from the
          -- conversation, so the user must have the necessary permission flag
          ensureActionAllowed RemoveConversationMember self
        Nothing ->
          when (Public.cupAccessRole target == TeamAccessRole) $
            throwErrorDescriptionType @InvalidTargetAccess
    _ -> pure ()

ensureGroupConvThrowing :: Data.Conversation -> Galley ()
ensureGroupConvThrowing conv = case Data.convType conv of
  SelfConv -> throwM invalidSelfOp
  One2OneConv -> throwM invalidOne2OneOp
  ConnectConv -> throwM invalidConnectOp
  _ -> pure ()

-- | Ensure that the set of actions provided are not "greater" than the user's
--   own. This is used to ensure users cannot "elevate" allowed actions
--   This function needs to be review when custom roles are introduced since only
--   custom roles can cause `roleNameToActions` to return a Nothing
ensureConvRoleNotElevated :: IsConvMember mem => mem -> RoleName -> Galley ()
ensureConvRoleNotElevated origMember targetRole = do
  case (roleNameToActions targetRole, roleNameToActions (convMemberRole origMember)) of
    (Just targetActions, Just memberActions) ->
      unless (Set.isSubsetOf targetActions memberActions) $
        throwM invalidActions
    (_, _) ->
      throwM (badRequest "Custom roles not supported")

-- | If a team member is not given throw 'notATeamMember'; if the given team
-- member does not have the given permission, throw 'operationDenied'.
-- Otherwise, return the team member.
permissionCheck :: (IsPerm perm, Show perm) => perm -> Maybe TeamMember -> Galley TeamMember
permissionCheck p = \case
  Just m -> do
    if m `hasPermission` p
      then pure m
      else throwErrorDescription (operationDenied p)
  Nothing -> throwErrorDescriptionType @NotATeamMember

assertTeamExists :: TeamId -> Galley ()
assertTeamExists tid = do
  teamExists <- isJust <$> Data.team tid
  if teamExists
    then pure ()
    else throwM teamNotFound

assertOnTeam :: UserId -> TeamId -> Galley ()
assertOnTeam uid tid = do
  Data.teamMember tid uid >>= \case
    Nothing -> throwErrorDescriptionType @NotATeamMember
    Just _ -> return ()

-- | If the conversation is in a team, throw iff zusr is a team member and does not have named
-- permission.  If the conversation is not in a team, do nothing (no error).
permissionCheckTeamConv :: UserId -> ConvId -> Perm -> Galley ()
permissionCheckTeamConv zusr cnv perm =
  Data.conversation cnv >>= \case
    Just cnv' -> case Data.convTeam cnv' of
      Just tid -> void $ permissionCheck perm =<< Data.teamMember tid zusr
      Nothing -> pure ()
    Nothing -> throwErrorDescriptionType @ConvNotFound

-- | Try to accept a 1-1 conversation, promoting connect conversations as appropriate.
acceptOne2One :: UserId -> Data.Conversation -> Maybe ConnId -> Galley Data.Conversation
acceptOne2One usr conv conn = do
  lusr <- qualifyLocal usr
  lcid <- qualifyLocal cid
  case Data.convType conv of
    One2OneConv ->
      if usr `isMember` mems
        then return conv
        else do
          mm <- Data.addMember lcid lusr
          return $ conv {Data.convLocalMembers = mems <> toList mm}
    ConnectConv -> case mems of
      [_, _] | usr `isMember` mems -> promote
      [_, _] -> throwErrorDescriptionType @ConvNotFound
      _ -> do
        when (length mems > 2) $
          throwM badConvState
        now <- liftIO getCurrentTime
        mm <- Data.addMember lcid lusr
        let e = memberJoinEvent lusr (unTagged lcid) now mm []
        conv' <- if isJust (find ((usr /=) . lmId) mems) then promote else pure conv
        let mems' = mems <> toList mm
        for_ (newPushLocal ListComplete usr (ConvEvent e) (recipient <$> mems')) $ \p ->
          push1 $ p & pushConn .~ conn & pushRoute .~ RouteDirect
        return $ conv' {Data.convLocalMembers = mems'}
    _ -> throwM $ invalidOp "accept: invalid conversation type"
  where
    cid = Data.convId conv
    mems = Data.convLocalMembers conv
    promote = do
      Data.acceptConnect cid
      return $ conv {Data.convType = One2OneConv}
    badConvState =
      mkError status500 "bad-state" $
        "Connect conversation with more than 2 members: "
          <> LT.pack (show cid)

memberJoinEvent ::
  Local UserId ->
  Qualified ConvId ->
  UTCTime ->
  [LocalMember] ->
  [RemoteMember] ->
  Event
memberJoinEvent lorig qconv t lmems rmems =
  Event MemberJoin qconv (unTagged lorig) t $
    EdMembersJoin (SimpleMembers (map localToSimple lmems <> map remoteToSimple rmems))
  where
    localToSimple u = SimpleMember (unTagged (qualifyAs lorig (lmId u))) (lmConvRoleName u)
    remoteToSimple u = SimpleMember (unTagged (rmId u)) (rmConvRoleName u)

isBot :: LocalMember -> Bool
isBot = isJust . lmService

isMember :: Foldable m => UserId -> m LocalMember -> Bool
isMember u = isJust . find ((u ==) . lmId)

isRemoteMember :: Foldable m => Remote UserId -> m RemoteMember -> Bool
isRemoteMember u = isJust . find ((u ==) . rmId)

class IsConvMember mem => IsConvMemberId uid mem | uid -> mem where
  getConvMember :: Local x -> Data.Conversation -> uid -> Maybe mem

  isConvMember :: Local x -> Data.Conversation -> uid -> Bool
  isConvMember loc conv = isJust . getConvMember loc conv

  notIsConvMember :: Local x -> Data.Conversation -> uid -> Bool
  notIsConvMember loc conv = not . isConvMember loc conv

instance IsConvMemberId UserId LocalMember where
  getConvMember _ conv u = find ((u ==) . lmId) (Data.convLocalMembers conv)

instance IsConvMemberId (Local UserId) LocalMember where
  getConvMember loc conv = getConvMember loc conv . lUnqualified

instance IsConvMemberId (Remote UserId) RemoteMember where
  getConvMember _ conv u = find ((u ==) . rmId) (Data.convRemoteMembers conv)

instance IsConvMemberId (Qualified UserId) (Either LocalMember RemoteMember) where
  getConvMember loc conv =
    foldQualified
      loc
      (fmap Left . getConvMember loc conv)
      (fmap Right . getConvMember loc conv)

class IsConvMember mem where
  convMemberRole :: mem -> RoleName
  convMemberId :: Local x -> mem -> Qualified UserId

instance IsConvMember LocalMember where
  convMemberRole = lmConvRoleName
  convMemberId loc mem = unTagged (qualifyAs loc (lmId mem))

instance IsConvMember RemoteMember where
  convMemberRole = rmConvRoleName
  convMemberId _ = unTagged . rmId

instance IsConvMember (Either LocalMember RemoteMember) where
  convMemberRole = either convMemberRole convMemberRole
  convMemberId loc = either (convMemberId loc) (convMemberId loc)

-- | Remove users that are already present in the conversation.
ulNewMembers :: Local x -> Data.Conversation -> UserList UserId -> UserList UserId
ulNewMembers loc conv (UserList locals remotes) =
  UserList
    (filter (notIsConvMember loc conv) locals)
    (filter (notIsConvMember loc conv) remotes)

-- | This is an ad-hoc class to update notification targets based on the type
-- of the user id. Local user IDs get added to the local targets, remote user IDs
-- to remote targets, and qualified user IDs get added to the appropriate list
-- according to whether they are local or remote, by making a runtime check.
class IsNotificationTarget uid where
  ntAdd :: Local x -> uid -> NotificationTargets -> NotificationTargets

data NotificationTargets = NotificationTargets
  { ntLocals :: Set UserId,
    ntRemotes :: Set (Remote UserId),
    ntBots :: Set BotMember
  }

instance Semigroup NotificationTargets where
  NotificationTargets locals1 remotes1 bots1
    <> NotificationTargets locals2 remotes2 bots2 =
      NotificationTargets
        (locals1 <> locals2)
        (remotes1 <> remotes2)
        (bots1 <> bots2)

instance Monoid NotificationTargets where
  mempty = NotificationTargets mempty mempty mempty

instance IsNotificationTarget (Local UserId) where
  ntAdd _ luid nt =
    nt {ntLocals = Set.insert (lUnqualified luid) (ntLocals nt)}

instance IsNotificationTarget (Remote UserId) where
  ntAdd _ ruid nt = nt {ntRemotes = Set.insert ruid (ntRemotes nt)}

instance IsNotificationTarget (Qualified UserId) where
  ntAdd loc = foldQualified loc (ntAdd loc) (ntAdd loc)

ntFromMembers :: [LocalMember] -> [RemoteMember] -> NotificationTargets
ntFromMembers lmems rusers = case localBotsAndUsers lmems of
  (bots, lusers) ->
    NotificationTargets
      { ntLocals = Set.fromList (map lmId lusers),
        ntRemotes = Set.fromList (map rmId rusers),
        ntBots = Set.fromList bots
      }

convTargets :: Data.Conversation -> NotificationTargets
convTargets conv = ntFromMembers (Data.convLocalMembers conv) (Data.convRemoteMembers conv)

localBotsAndUsers :: Foldable f => f LocalMember -> ([BotMember], [LocalMember])
localBotsAndUsers = foldMap botOrUser
  where
    botOrUser m = case lmService m of
      -- we drop invalid bots here, which shouldn't happen
      Just _ -> (toList (newBotMember m), [])
      Nothing -> ([], [m])

location :: ToByteString a => a -> Response -> Response
location = addHeader hLocation . toByteString'

nonTeamMembers :: [LocalMember] -> [TeamMember] -> [LocalMember]
nonTeamMembers cm tm = filter (not . isMemberOfTeam . lmId) cm
  where
    -- FUTUREWORK: remote members: teams and their members are always on the same backend
    isMemberOfTeam = \case
      uid -> isTeamMember uid tm

convMembsAndTeamMembs :: [LocalMember] -> [TeamMember] -> [Recipient]
convMembsAndTeamMembs convMembs teamMembs =
  fmap userRecipient . setnub $ map lmId convMembs <> map (view userId) teamMembs
  where
    setnub = Set.toList . Set.fromList

membersToRecipients :: Maybe UserId -> [TeamMember] -> [Recipient]
membersToRecipients Nothing = map (userRecipient . view userId)
membersToRecipients (Just u) = map userRecipient . filter (/= u) . map (view userId)

-- | Note that we use 2 nearly identical functions but slightly different
-- semantics; when using `getSelfMemberFromLocals`, if that user is _not_ part
-- of the conversation, we don't want to disclose that such a conversation with
-- that id exists.
getSelfMemberFromLocals ::
  (Foldable t, Monad m) =>
  UserId ->
  t LocalMember ->
  ExceptT ConvNotFound m LocalMember
getSelfMemberFromLocals = getLocalMember (mkErrorDescription :: ConvNotFound)

-- | A legacy version of 'getSelfMemberFromLocals' that runs in the Galley monad.
getSelfMemberFromLocalsLegacy ::
  Foldable t =>
  UserId ->
  t LocalMember ->
  Galley LocalMember
getSelfMemberFromLocalsLegacy usr lmems =
  eitherM throwErrorDescription pure . runExceptT $ getSelfMemberFromLocals usr lmems

-- | Throw 'ConvMemberNotFound' if the given user is not part of a
-- conversation (either locally or remotely).
ensureOtherMember ::
  Local a ->
  Qualified UserId ->
  Data.Conversation ->
  Galley (Either LocalMember RemoteMember)
ensureOtherMember loc quid conv =
  maybe (throwErrorDescriptionType @ConvMemberNotFound) pure $
    (Left <$> find ((== quid) . (`Qualified` lDomain loc) . lmId) (Data.convLocalMembers conv))
      <|> (Right <$> find ((== quid) . unTagged . rmId) (Data.convRemoteMembers conv))

-- | Note that we use 2 nearly identical functions but slightly different
-- semantics; when using `getSelfMemberQualified`, if that user is _not_ part of
-- the conversation, we don't want to disclose that such a conversation with
-- that id exists.
getSelfMemberQualified ::
  (Foldable t, Monad m) =>
  Domain ->
  Qualified UserId ->
  t LocalMember ->
  t RemoteMember ->
  ExceptT ConvNotFound m (Either LocalMember RemoteMember)
getSelfMemberQualified localDomain qusr@(Qualified usr userDomain) lmems rmems = do
  if localDomain == userDomain
    then Left <$> getSelfMemberFromLocals usr lmems
    else Right <$> getSelfMemberFromRemotes (toRemote qusr) rmems

getSelfMemberFromRemotes ::
  (Foldable t, Monad m) =>
  Remote UserId ->
  t RemoteMember ->
  ExceptT ConvNotFound m RemoteMember
getSelfMemberFromRemotes = getRemoteMember (mkErrorDescription :: ConvNotFound)

getSelfMemberFromRemotesLegacy :: Foldable t => Remote UserId -> t RemoteMember -> Galley RemoteMember
getSelfMemberFromRemotesLegacy usr rmems =
  eitherM throwErrorDescription pure . runExceptT $
    getSelfMemberFromRemotes usr rmems

-- | Since we search by local user ID, we know that the member must be local.
getLocalMember ::
  (Foldable t, Monad m) =>
  e ->
  UserId ->
  t LocalMember ->
  ExceptT e m LocalMember
getLocalMember = getMember lmId

-- | Since we search by remote user ID, we know that the member must be remote.
getRemoteMember ::
  (Foldable t, Monad m) =>
  e ->
  Remote UserId ->
  t RemoteMember ->
  ExceptT e m RemoteMember
getRemoteMember = getMember rmId

getQualifiedMember ::
  Monad m =>
  Local x ->
  e ->
  Qualified UserId ->
  Data.Conversation ->
  ExceptT e m (Either LocalMember RemoteMember)
getQualifiedMember loc e qusr conv =
  foldQualified
    loc
    (\lusr -> Left <$> getLocalMember e (lUnqualified lusr) (Data.convLocalMembers conv))
    (\rusr -> Right <$> getRemoteMember e rusr (Data.convRemoteMembers conv))
    qusr

getMember ::
  (Foldable t, Eq userId, Monad m) =>
  -- | A projection from a member type to its user ID
  (mem -> userId) ->
  -- | An error to throw in case the user is not in the list
  e ->
  -- | The member to be found by its user ID
  userId ->
  -- | A list of members to search
  t mem ->
  ExceptT e m mem
getMember p ex u = hoistEither . note ex . find ((u ==) . p)

getConversationAndCheckMembership :: UserId -> ConvId -> Galley Data.Conversation
getConversationAndCheckMembership uid cnv = do
  (conv, _) <-
    getConversationAndMemberWithError
      (errorDescriptionTypeToWai @ConvAccessDenied)
      uid
      cnv
  pure conv

getConversationAndMemberWithError ::
  IsConvMemberId uid mem =>
  Error ->
  uid ->
  ConvId ->
  Galley (Data.Conversation, mem)
getConversationAndMemberWithError ex usr convId = do
  c <- Data.conversation convId >>= ifNothing (errorDescriptionTypeToWai @ConvNotFound)
  when (DataTypes.isConvDeleted c) $ do
    Data.deleteConversation convId
    throwErrorDescriptionType @ConvNotFound
  loc <- qualifyLocal ()
  member <-
    either throwM pure . note ex $
      getConvMember loc c usr
  pure (c, member)

-- | Deletion requires a permission check, but also a 'Role' comparison:
-- Owners can only be deleted by another owner (and not themselves).
--
-- FUTUREWORK: do not do this with 'Role', but introduce permissions "can delete owner", "can
-- delete admin", etc.
canDeleteMember :: TeamMember -> TeamMember -> Bool
canDeleteMember deleter deletee
  | getRole deletee == RoleOwner =
    getRole deleter == RoleOwner -- owners can only be deleted by another owner
      && (deleter ^. userId /= deletee ^. userId) -- owner cannot delete itself
  | otherwise =
    True
  where
    -- (team members having no role is an internal error, but we don't want to deal with that
    -- here, so we pick a reasonable default.)
    getRole mem = fromMaybe RoleMember $ permissionsRole $ mem ^. permissions

-- | Send an event to local users and bots
pushConversationEvent :: Foldable f => Maybe ConnId -> Event -> f UserId -> f BotMember -> Galley ()
pushConversationEvent conn e users bots = do
  localDomain <- viewFederationDomain
  for_ (newConversationEventPush localDomain e (toList users)) $ \p ->
    push1 $ p & set pushConn conn
  void . forkIO $ void $ External.deliver (toList bots `zip` repeat e)

verifyReusableCode :: ConversationCode -> Galley DataTypes.Code
verifyReusableCode convCode = do
  c <-
    Data.lookupCode (conversationKey convCode) DataTypes.ReusableCode
      >>= ifNothing (errorDescriptionTypeToWai @CodeNotFound)
  unless (DataTypes.codeValue c == conversationCode convCode) $
    throwM (errorDescriptionTypeToWai @CodeNotFound)
  return c

ensureConversationAccess :: UserId -> ConvId -> Access -> Galley Data.Conversation
ensureConversationAccess zusr cnv access = do
  conv <- Data.conversation cnv >>= ifNothing (errorDescriptionTypeToWai @ConvNotFound)
  ensureAccess conv access
  zusrMembership <- maybe (pure Nothing) (`Data.teamMember` zusr) (Data.convTeam conv)
  ensureAccessRole (Data.convAccessRole conv) [(zusr, zusrMembership)]
  pure conv

ensureAccess :: Data.Conversation -> Access -> Galley ()
ensureAccess conv access =
  unless (access `elem` Data.convAccess conv) $
    throwErrorDescriptionType @ConvAccessDenied

--------------------------------------------------------------------------------
-- Federation

viewFederationDomain :: MonadReader Env m => m Domain
viewFederationDomain = view (options . optSettings . setFederationDomain)

qualifyLocal :: MonadReader Env m => a -> m (Local a)
qualifyLocal a = fmap (toLocal . Qualified a) viewFederationDomain

checkRemoteUsersExist :: (Functor f, Foldable f) => f (Remote UserId) -> Galley ()
checkRemoteUsersExist =
  -- FUTUREWORK: pooledForConcurrentlyN_ instead of sequential checks per domain
  traverse_ (uncurry checkRemotesFor)
    . partitionRemote

checkRemotesFor :: Domain -> [UserId] -> Galley ()
checkRemotesFor domain uids = do
  let rpc = FederatedBrig.getUsersByIds FederatedBrig.clientRoutes uids
  users <- runFederatedBrig domain rpc
  let uids' =
        map
          (qUnqualified . User.profileQualifiedId)
          (filter (not . User.profileDeleted) users)
  unless (Set.fromList uids == Set.fromList uids') $
    throwM unknownRemoteUser

type FederatedGalleyRPC c a = FederatorClient c (ExceptT FederationClientFailure Galley) a

runFederatedGalley :: Domain -> FederatedGalleyRPC 'Galley a -> Galley a
runFederatedGalley = runFederated @'Galley

runFederatedBrig :: Domain -> FederatedGalleyRPC 'Brig a -> Galley a
runFederatedBrig = runFederated @'Brig

runFederated :: forall (c :: Component) a. Domain -> FederatorClient c (ExceptT FederationClientFailure Galley) a -> Galley a
runFederated remoteDomain rpc = do
  runExceptT (executeFederated remoteDomain rpc)
    >>= either (throwM . federationErrorToWai) pure

-- | Convert an internal conversation representation 'Data.Conversation' to
-- 'NewRemoteConversation' to be sent over the wire to a remote backend that will
-- reconstruct this into multiple public-facing
-- 'Wire.API.Conversation.Convevrsation' values, one per user from that remote
-- backend.
--
-- FUTUREWORK: Include the team ID as well once it becomes qualified.
toNewRemoteConversation ::
  -- | The time stamp the conversation was created at
  UTCTime ->
  -- | The domain of the user that created the conversation
  Domain ->
  -- | The conversation to convert for sending to a remote Galley
  Data.Conversation ->
  -- | The resulting information to be sent to a remote Galley
  NewRemoteConversation ConvId
toNewRemoteConversation now localDomain Data.Conversation {..} =
  NewRemoteConversation
    { rcTime = now,
      rcOrigUserId = Qualified convCreator localDomain,
      rcCnvId = convId,
      rcCnvType = convType,
      rcCnvAccess = convAccess,
      rcCnvAccessRole = convAccessRole,
      rcCnvName = convName,
      rcMembers = toMembers convLocalMembers convRemoteMembers,
      rcMessageTimer = convMessageTimer,
      rcReceiptMode = convReceiptMode
    }
  where
    toMembers ::
      [LocalMember] ->
      [RemoteMember] ->
      Set OtherMember
    toMembers ls rs =
      Set.fromList $
        map (localMemberToOther localDomain) ls
          <> map remoteMemberToOther rs

-- | The function converts a 'NewRemoteConversation' value to a
-- 'Wire.API.Conversation.Conversation' value for each user that is on the given
-- domain/backend. The obtained value can be used in e.g. creating an 'Event' to
-- be sent out to users informing them that they were added to a new
-- conversation.
fromNewRemoteConversation ::
  Domain ->
  NewRemoteConversation (Qualified ConvId) ->
  [(Public.Member, Public.Conversation)]
fromNewRemoteConversation d NewRemoteConversation {..} =
  let membersView = fmap (second Set.toList) . setHoles $ rcMembers
   in foldMap
        ( \(me, others) ->
            guard (inDomain me) $> let mem = toMember me in (mem, conv mem others)
        )
        membersView
  where
    inDomain :: OtherMember -> Bool
    inDomain = (== d) . qDomain . omQualifiedId
    setHoles :: Ord a => Set a -> [(a, Set a)]
    setHoles s = foldMap (\x -> [(x, Set.delete x s)]) s
    -- Currently this function creates a Member with default conversation attributes
    -- FUTUREWORK(federation): retrieve member's conversation attributes (muted, archived, etc) here once supported by the database schema.
    toMember :: OtherMember -> Public.Member
    toMember m =
      Public.Member
        { memId = qUnqualified . omQualifiedId $ m,
          memService = omService m,
          memOtrMutedStatus = Nothing,
          memOtrMutedRef = Nothing,
          memOtrArchived = False,
          memOtrArchivedRef = Nothing,
          memHidden = False,
          memHiddenRef = Nothing,
          memConvRoleName = omConvRoleName m
        }
    conv :: Public.Member -> [OtherMember] -> Public.Conversation
    conv this others =
      Public.Conversation
        ConversationMetadata
          { cnvmQualifiedId = rcCnvId,
            cnvmType = rcCnvType,
            -- FUTUREWORK: Document this is the same domain as the conversation
            -- domain
            cnvmCreator = qUnqualified rcOrigUserId,
            cnvmAccess = rcCnvAccess,
            cnvmAccessRole = rcCnvAccessRole,
            cnvmName = rcCnvName,
            -- FUTUREWORK: Document this is the same domain as the conversation
            -- domain.
            cnvmTeam = Nothing,
            cnvmMessageTimer = rcMessageTimer,
            cnvmReceiptMode = rcReceiptMode
          }
        (ConvMembers this others)

-- | Notify remote users of being added to a new conversation
registerRemoteConversationMemberships ::
  -- | The time stamp when the conversation was created
  UTCTime ->
  -- | The domain of the user that created the conversation
  Domain ->
  Data.Conversation ->
  Galley ()
registerRemoteConversationMemberships now localDomain c = do
  let rc = toNewRemoteConversation now localDomain c
  -- FUTUREWORK: parallelise federated requests
  traverse_ (registerRemoteConversations rc)
    . Map.keys
    . partitionQualified
    . nubOrd
    . map (unTagged . rmId)
    . Data.convRemoteMembers
    $ c
  where
    registerRemoteConversations ::
      NewRemoteConversation ConvId ->
      Domain ->
      Galley ()
    registerRemoteConversations rc domain = do
      let rpc = FederatedGalley.onConversationCreated FederatedGalley.clientRoutes localDomain rc
      runFederated domain rpc

--------------------------------------------------------------------------------
-- Legalhold

userLHEnabled :: UserLegalHoldStatus -> Bool
userLHEnabled = \case
  UserLegalHoldEnabled -> True
  UserLegalHoldPending -> True
  UserLegalHoldDisabled -> False
  UserLegalHoldNoConsent -> False

data ConsentGiven = ConsentGiven | ConsentNotGiven
  deriving (Eq, Ord, Show)

consentGiven :: UserLegalHoldStatus -> ConsentGiven
consentGiven = \case
  UserLegalHoldDisabled -> ConsentGiven
  UserLegalHoldPending -> ConsentGiven
  UserLegalHoldEnabled -> ConsentGiven
  UserLegalHoldNoConsent -> ConsentNotGiven

checkConsent :: Map UserId TeamId -> UserId -> Galley ConsentGiven
checkConsent teamsOfUsers other = do
  consentGiven <$> getLHStatus (Map.lookup other teamsOfUsers) other

-- Get legalhold status of user. Defaults to 'defUserLegalHoldStatus' if user
-- doesn't belong to a team.
getLHStatus :: Maybe TeamId -> UserId -> Galley UserLegalHoldStatus
getLHStatus teamOfUser other = do
  case teamOfUser of
    Nothing -> pure defUserLegalHoldStatus
    Just team -> do
      mMember <- Data.teamMember team other
      pure $ maybe defUserLegalHoldStatus (view legalHoldStatus) mMember

anyLegalholdActivated :: [UserId] -> Galley Bool
anyLegalholdActivated uids = do
  view (options . optSettings . setFeatureFlags . flagLegalHold) >>= \case
    FeatureLegalHoldDisabledPermanently -> pure False
    FeatureLegalHoldDisabledByDefault -> check
    FeatureLegalHoldWhitelistTeamsAndImplicitConsent -> check
  where
    check = do
      flip anyM (chunksOf 32 uids) $ \uidsPage -> do
        teamsOfUsers <- Data.usersTeams uidsPage
        anyM (\uid -> userLHEnabled <$> getLHStatus (Map.lookup uid teamsOfUsers) uid) uidsPage

allLegalholdConsentGiven :: [UserId] -> Galley Bool
allLegalholdConsentGiven uids = do
  view (options . optSettings . setFeatureFlags . flagLegalHold) >>= \case
    FeatureLegalHoldDisabledPermanently -> pure False
    FeatureLegalHoldDisabledByDefault -> do
      flip allM (chunksOf 32 uids) $ \uidsPage -> do
        teamsOfUsers <- Data.usersTeams uidsPage
        allM (\uid -> (== ConsentGiven) . consentGiven <$> getLHStatus (Map.lookup uid teamsOfUsers) uid) uidsPage
    FeatureLegalHoldWhitelistTeamsAndImplicitConsent -> do
      -- For this feature the implementation is more efficient. Being part of
      -- a whitelisted team is equivalent to have given consent to be in a
      -- conversation with user under legalhold.
      flip allM (chunksOf 32 uids) $ \uidsPage -> do
        teamsPage <- nub . Map.elems <$> Data.usersTeams uidsPage
        allM isTeamLegalholdWhitelisted teamsPage

-- | Add to every uid the legalhold status
getLHStatusForUsers :: [UserId] -> Galley [(UserId, UserLegalHoldStatus)]
getLHStatusForUsers uids =
  mconcat
    <$> ( for (chunksOf 32 uids) $ \uidsChunk -> do
            teamsOfUsers <- Data.usersTeams uidsChunk
            for uidsChunk $ \uid -> do
              (uid,) <$> getLHStatus (Map.lookup uid teamsOfUsers) uid
        )
