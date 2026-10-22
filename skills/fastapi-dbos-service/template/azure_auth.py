"""
Azure AD (Entra ID) bearer token validation.

DEV_MODE=true bypasses real Azure AD so you can run the whole stack locally
without a tenant. Flip it off and set the AZURE_* env vars to test against
your real app registration.
"""

import os

from fastapi import Depends

DEV_MODE = os.environ.get("DEV_MODE", "false").lower() == "true"

AZURE_TENANT_ID = os.environ.get("AZURE_TENANT_ID", "")
AZURE_CLIENT_ID = os.environ.get("AZURE_CLIENT_ID", "")
AZURE_SCOPE_NAME = os.environ.get("AZURE_SCOPE_NAME", "access_as_user")

if DEV_MODE:

    async def get_current_user() -> dict:
        """Fake user, no token required. Only used when DEV_MODE=true."""
        return {
            "name": "Local Dev User",
            "preferred_username": "dev@localhost",
            "roles": ["dev"],
        }

else:
    from fastapi_azure_auth import SingleTenantAzureAuthorizationCodeBearer

    azure_scheme = SingleTenantAzureAuthorizationCodeBearer(
        app_client_id=AZURE_CLIENT_ID,
        tenant_id=AZURE_TENANT_ID,
        scopes={f"api://{AZURE_CLIENT_ID}/{AZURE_SCOPE_NAME}": AZURE_SCOPE_NAME},
    )

    async def get_current_user(token: dict = Depends(azure_scheme)) -> dict:
        """Real Azure AD validation. `token` is the decoded claims dict."""
        return {
            "name": token.get("name"),
            "preferred_username": token.get("preferred_username"),
            "roles": token.get("roles", []),
        }
