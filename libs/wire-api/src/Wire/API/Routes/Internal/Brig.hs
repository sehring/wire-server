-- This file is part of the Wire Server implementation.
--
-- Copyright (C) 2022 Wire Swiss GmbH <opensource@wire.com>
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

module Wire.API.Routes.Internal.Brig
  ( API,
    IStatusAPI,
    EJPD_API,
    AccountAPI,
    MLSAPI,
    TeamsAPI,
    UserAPI,
    ClientAPI,
    AuthAPI,
    FederationRemotesAPI,
    EJPDRequest,
    ISearchIndexAPI,
    GetAccountConferenceCallingConfig,
    PutAccountConferenceCallingConfig,
    DeleteAccountConferenceCallingConfig,
    swaggerDoc,
    module Wire.API.Routes.Internal.Brig.EJPD,
  )
where

import Control.Lens ((.~))
import Data.Aeson (FromJSON, ToJSON)
import qualified Data.Code as Code
import Data.Domain (Domain)
import Data.Id as Id
import Data.Qualified (Qualified)
import Data.Schema hiding (swaggerDoc)
import Data.Swagger (HasInfo (info), HasTitle (title), Swagger)
import qualified Data.Swagger as S
import Imports hiding (head)
import Servant hiding (Handler, WithStatus, addHeader, respond)
import Servant.Swagger (HasSwagger (toSwagger))
import Servant.Swagger.Internal.Orphans ()
import Wire.API.Connection
import Wire.API.Error
import Wire.API.Error.Brig
import Wire.API.MLS.CipherSuite (SignatureSchemeTag)
import Wire.API.MakesFederatedCall
import Wire.API.Routes.FederationDomainConfig
import Wire.API.Routes.Internal.Brig.Connection
import Wire.API.Routes.Internal.Brig.EJPD
import Wire.API.Routes.Internal.Brig.OAuth (OAuthAPI)
import Wire.API.Routes.Internal.Brig.SearchIndex (ISearchIndexAPI)
import qualified Wire.API.Routes.Internal.Galley.TeamFeatureNoConfigMulti as Multi
import Wire.API.Routes.MultiVerb
import Wire.API.Routes.Named
import Wire.API.Routes.Public (ZUser {- yes, this is a bit weird -})
import Wire.API.Team.Feature
import Wire.API.User
import Wire.API.User.Auth
import Wire.API.User.Auth.LegalHold
import Wire.API.User.Auth.ReAuth
import Wire.API.User.Auth.Sso
import Wire.API.User.Client

type EJPDRequest =
  Summary
    "Identify users for law enforcement.  Wire has legal requirements to cooperate \
    \with the authorities.  The wire backend operations team uses this to answer \
    \identification requests manually.  It is our best-effort representation of the \
    \minimum required information we need to hand over about targets and (in some \
    \cases) their communication peers.  For more information, consult ejpd.admin.ch."
    :> "ejpd-request"
    :> QueryParam'
         [ Optional,
           Strict,
           Description "Also provide information about all contacts of the identified users"
         ]
         "include_contacts"
         Bool
    :> Servant.ReqBody '[Servant.JSON] EJPDRequestBody
    :> Post '[Servant.JSON] EJPDResponseBody

type GetAccountConferenceCallingConfig =
  Summary
    "Read cassandra field 'brig.user.feature_conference_calling'"
    :> "users"
    :> Capture "uid" UserId
    :> "features"
    :> "conferenceCalling"
    :> Get '[Servant.JSON] (WithStatusNoLock ConferenceCallingConfig)

type PutAccountConferenceCallingConfig =
  Summary
    "Write to cassandra field 'brig.user.feature_conference_calling'"
    :> "users"
    :> Capture "uid" UserId
    :> "features"
    :> "conferenceCalling"
    :> Servant.ReqBody '[Servant.JSON] (WithStatusNoLock ConferenceCallingConfig)
    :> Put '[Servant.JSON] NoContent

type DeleteAccountConferenceCallingConfig =
  Summary
    "Reset cassandra field 'brig.user.feature_conference_calling' to 'null'"
    :> "users"
    :> Capture "uid" UserId
    :> "features"
    :> "conferenceCalling"
    :> Delete '[Servant.JSON] NoContent

type GetAllConnectionsUnqualified =
  Summary "Get all connections of a given user"
    :> "users"
    :> "connections-status"
    :> ReqBody '[Servant.JSON] ConnectionsStatusRequest
    :> QueryParam'
         [ Optional,
           Strict,
           Description "Only returns connections with the given relation, if omitted, returns all connections"
         ]
         "filter"
         Relation
    :> Post '[Servant.JSON] [ConnectionStatus]

type GetAllConnections =
  Summary "Get all connections of a given user"
    :> "users"
    :> "connections-status"
    :> "v2"
    :> ReqBody '[Servant.JSON] ConnectionsStatusRequestV2
    :> Post '[Servant.JSON] [ConnectionStatusV2]

type EJPD_API =
  ( EJPDRequest
      :<|> Named "get-account-conference-calling-config" GetAccountConferenceCallingConfig
      :<|> PutAccountConferenceCallingConfig
      :<|> DeleteAccountConferenceCallingConfig
      :<|> GetAllConnectionsUnqualified
      :<|> GetAllConnections
  )

type AccountAPI =
  -- This endpoint can lead to the following events being sent:
  -- - UserActivated event to created user, if it is a team invitation or user has an SSO ID
  -- - UserIdentityUpdated event to created user, if email or phone get activated
  Named
    "createUserNoVerify"
    ( "users"
        :> MakesFederatedCall 'Brig "on-user-deleted-connections"
        :> ReqBody '[Servant.JSON] NewUser
        :> MultiVerb 'POST '[Servant.JSON] RegisterInternalResponses (Either RegisterError SelfProfile)
    )
    :<|> Named
           "createUserNoVerifySpar"
           ( "users"
               :> "spar"
               :> MakesFederatedCall 'Brig "on-user-deleted-connections"
               :> ReqBody '[Servant.JSON] NewUserSpar
               :> MultiVerb 'POST '[Servant.JSON] CreateUserSparInternalResponses (Either CreateUserSparError SelfProfile)
           )
    :<|> Named
           "putSelfEmail"
           ( Summary
               "internal email activation (used in tests and in spar for validating emails obtained as \
               \SAML user identifiers).  if the validate query parameter is false or missing, only set \
               \the activation timeout, but do not send an email, and do not do anything about \
               \activating the email."
               :> ZUser
               :> "self"
               :> "email"
               :> ReqBody '[Servant.JSON] EmailUpdate
               :> QueryParam' [Optional, Strict, Description "whether to send validation email, or activate"] "validate" Bool
               :> MultiVerb
                    'PUT
                    '[Servant.JSON]
                    '[ Respond 202 "Update accepted and pending activation of the new email" (),
                       Respond 204 "No update, current and new email address are the same" ()
                     ]
                    ChangeEmailResponse
           )
    :<|> Named
           "iDeleteUser"
           ( Summary
               "This endpoint will lead to the following events being sent: UserDeleted event to all of \
               \its contacts, MemberLeave event to members for all conversations the user was in (via galley)"
               :> CanThrow 'UserNotFound
               :> "users"
               :> Capture "uid" UserId
               :> MultiVerb
                    'DELETE
                    '[Servant.JSON]
                    '[ Respond 200 "UserResponseAccountAlreadyDeleted" (),
                       Respond 202 "UserResponseAccountDeleted" ()
                     ]
                    DeleteUserResponse
           )
    :<|> Named
           "iPutUserStatus"
           ( -- FUTUREWORK: `CanThrow ... :>`
             "users"
               :> Capture "uid" UserId
               :> "status"
               :> ReqBody '[Servant.JSON] AccountStatusUpdate
               :> Put '[Servant.JSON] NoContent
           )
    :<|> Named
           "iGetUserStatus"
           ( CanThrow 'UserNotFound
               :> "users"
               :> Capture "uid" UserId
               :> "status"
               :> Get '[Servant.JSON] AccountStatusResp
           )

-- | The missing ref is implicit by the capture
data NewKeyPackageRef = NewKeyPackageRef
  { nkprUserId :: Qualified UserId,
    nkprClientId :: ClientId,
    nkprConversation :: Qualified ConvId
  }
  deriving stock (Eq, Show, Generic)
  deriving (ToJSON, FromJSON, S.ToSchema) via (Schema NewKeyPackageRef)

instance ToSchema NewKeyPackageRef where
  schema =
    object "NewKeyPackageRef" $
      NewKeyPackageRef
        <$> nkprUserId .= field "user_id" schema
        <*> nkprClientId .= field "client_id" schema
        <*> nkprConversation .= field "conversation" schema

type MLSAPI = "mls" :> GetMLSClients

type GetMLSClients =
  Summary "Return all clients and all MLS-capable clients of a user"
    :> "clients"
    :> CanThrow 'UserNotFound
    :> Capture "user" UserId
    :> QueryParam' '[Required, Strict] "sig_scheme" SignatureSchemeTag
    :> MultiVerb1
         'GET
         '[Servant.JSON]
         (Respond 200 "MLS clients" (Set ClientInfo))

type GetVerificationCode =
  Summary "Get verification code for a given email and action"
    :> "users"
    :> Capture "uid" UserId
    :> "verification-code"
    :> Capture "action" VerificationAction
    :> Get '[Servant.JSON] (Maybe Code.Value)

type API =
  "i"
    :> ( IStatusAPI
           :<|> EJPD_API
           :<|> AccountAPI
           :<|> MLSAPI
           :<|> GetVerificationCode
           :<|> TeamsAPI
           :<|> UserAPI
           :<|> ClientAPI
           :<|> AuthAPI
           :<|> OAuthAPI
           :<|> ISearchIndexAPI
           :<|> FederationRemotesAPI
       )

type IStatusAPI =
  Named
    "get-status"
    ( Summary "do nothing, just check liveness (NB: this works for both get, head)"
        :> "status"
        :> Get '[Servant.JSON] NoContent
    )

type TeamsAPI =
  Named
    "updateSearchVisibilityInbound"
    ( "teams"
        :> ReqBody '[Servant.JSON] (Multi.TeamStatus SearchVisibilityInboundConfig)
        :> Post '[Servant.JSON] ()
    )

type UserAPI =
  UpdateUserLocale
    :<|> DeleteUserLocale
    :<|> GetDefaultLocale

type UpdateUserLocale =
  Summary
    "Set the user's locale"
    :> "users"
    :> Capture "uid" UserId
    :> "locale"
    :> ReqBody '[Servant.JSON] LocaleUpdate
    :> Put '[Servant.JSON] LocaleUpdate

type DeleteUserLocale =
  Summary
    "Delete the user's locale"
    :> "users"
    :> Capture "uid" UserId
    :> "locale"
    :> Delete '[Servant.JSON] NoContent

type GetDefaultLocale =
  Summary "Get the default locale"
    :> "users"
    :> "locale"
    :> Get '[Servant.JSON] LocaleUpdate

type ClientAPI =
  Summary "Update last_active field of a client"
    :> "clients"
    :> Capture "uid" UserId
    :> Capture "client" ClientId
    :> "activity"
    :> MultiVerb1 'POST '[Servant.JSON] (RespondEmpty 200 "OK")

type AuthAPI =
  Named
    "legalhold-login"
    ( "legalhold-login"
        :> MakesFederatedCall 'Brig "on-user-deleted-connections"
        :> ReqBody '[JSON] LegalHoldLogin
        :> MultiVerb1 'POST '[JSON] TokenResponse
    )
    :<|> Named
           "sso-login"
           ( "sso-login"
               :> MakesFederatedCall 'Brig "on-user-deleted-connections"
               :> ReqBody '[JSON] SsoLogin
               :> QueryParam' [Optional, Strict] "persist" Bool
               :> MultiVerb1 'POST '[JSON] TokenResponse
           )
    :<|> Named
           "login-code"
           ( "users"
               :> "login-code"
               :> QueryParam' [Required, Strict] "phone" Phone
               :> MultiVerb1 'GET '[JSON] (Respond 200 "Login code" PendingLoginCode)
           )
    :<|> Named
           "reauthenticate"
           ( "users"
               :> Capture "uid" UserId
               :> "reauthenticate"
               :> ReqBody '[JSON] ReAuthUser
               :> MultiVerb1 'GET '[JSON] (RespondEmpty 200 "OK")
           )

-- | This is located in brig, not in federator, because brig has a cassandra instance.  This
-- is not ideal, and other services could keep their local in-ram copy of this table up to date
-- via rabbitmq, but FUTUREWORK.
type FederationRemotesAPI =
  Named
    "add-federation-remotes"
    ( Description FederationRemotesAPIDescription
        :> "federation"
        :> "remotes"
        :> ReqBody '[JSON] FederationDomainConfig
        :> Post '[JSON] ()
    )
    :<|> Named
           "get-federation-remotes"
           ( Description FederationRemotesAPIDescription
               :> "federation"
               :> "remotes"
               :> Get '[JSON] FederationDomainConfigs
           )
    :<|> Named
           "update-federation-remotes"
           ( Description FederationRemotesAPIDescription
               :> "federation"
               :> "remotes"
               :> Capture "domain" Domain
               :> ReqBody '[JSON] FederationDomainConfig
               :> Put '[JSON] ()
           )
    :<|> Named
           "delete-federation-remotes"
           ( Description FederationRemotesAPIDescription
               :> Description FederationRemotesAPIDeleteDescription
               :> "federation"
               :> "remotes"
               :> Capture "domain" Domain
               :> Delete '[JSON] ()
           )

type FederationRemotesAPIDescription =
  "See https://docs.wire.com/understand/federation/backend-communication.html#configuring-remote-connections for background. "

type FederationRemotesAPIDeleteDescription =
  "**WARNING!** If you remove a remote connection, all users from that remote will be removed from local conversations, and all \
  \group conversations hosted by that remote will be removed from the local backend. This cannot be reverted! "

swaggerDoc :: Swagger
swaggerDoc =
  toSwagger (Proxy @API)
    & info . title .~ "Wire-Server internal brig API"
