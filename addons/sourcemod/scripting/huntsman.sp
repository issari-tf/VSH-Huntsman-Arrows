#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>
#include <tf2_stocks>
#include <vector>
#include <saxtonhale>

#define PLUGIN_VERSION          "1.0.0"
#define PLUGIN_VERSION_REVISION "manual"

#define ARRAY_ENTITY_SIZE       5

#define HUNTSMAN                56
#define FESTIVE                 1005
#define COMPOUND                1092

enum EntityData 
{
	EntityData_EntityRef,
	EntityData_Enabled,
	EntityData_Bounces
};

ArrayList g_ModifiedEntities;
int       g_BouncyClients[MAXPLAYERS + 1];
int       g_iLastButtons[MAXPLAYERS + 1];

ConVar g_CvarDefaultBounceState;
ConVar g_CvarTimeToStartBouncing;
ConVar g_CvarMaxProjectiles;
ConVar g_CvarMaxBounces;

public Plugin myinfo = 
{
	name        = "Huntsman Arrows",
	author      = "Aidan Sanders",
	description = "VSH Subplugin allowing Arrows to Bounce off walls",
	version     = "1.0.0"
};

public void OnPluginStart()
{
	g_ModifiedEntities = CreateArray(ARRAY_ENTITY_SIZE);

	g_CvarDefaultBounceState  = CreateConVar("bp_default_bounce", "0", "Default bouncy state for all players", FCVAR_NONE, true, 0.0, true, 1.0);
	g_CvarTimeToStartBouncing = CreateConVar("bp_start_delay", "0.01", "Delay before projectile becomes bouncy", FCVAR_NONE, true, 0.0);
	g_CvarMaxProjectiles      = CreateConVar("bp_max_projectiles", "50", "Maximum number of bouncy projectiles at once", FCVAR_NONE, true, 1.0);
	g_CvarMaxBounces          = CreateConVar("bp_max_bounces", "3", "Max number of bounces per projectile", FCVAR_NONE, true, 1.0);

	LoadTranslations("common.phrases");
	
	// Incase of lateload
	for (int iClient = 1; iClient <= MaxClients; iClient++)
	{
		if (IsClientInGame(iClient))
		{
			OnClientPutInServer(iClient);
		}
	}
}

public void OnPluginEnd()
{
	CleanupModifiedEntities();
}

void CleanupModifiedEntities() 
{
	int iCount = g_ModifiedEntities.Length;
	int iData[ARRAY_ENTITY_SIZE];

	// We'll create a new temp array to hold alive entries
	ArrayList aTemp = CreateArray(ARRAY_ENTITY_SIZE);

	for (int i = 0; i < iCount; i++) 
	{
		g_ModifiedEntities.GetArray(i, iData);
		if (iData[EntityData_EntityRef] != 0) 
		{
			aTemp.PushArray(iData);
		}
	}

	// Clear the old list and replace with compacted one
	g_ModifiedEntities.Clear();
	int iNewCount = aTemp.Length;

	for (int i = 0; i < iNewCount; i++) 
	{
		aTemp.GetArray(i, iData);
		g_ModifiedEntities.PushArray(iData);
	}

	CloseHandle(aTemp);
}

public Action OnPlayerRunCmd(int iClient, int &iButtons, int &iImpulse, 
														 float flVel[3], float flAngles[3], int &iWeapon, 
														 int &iSubType, int &iCmdNum, int &iTickCount, 
														 int &iSeed, int iMouse[2])
{
	if (iClient <= 0 || iClient > MaxClients || !IsClientInGame(iClient)) 
		return Plugin_Continue;

	if (!IsHoldingHuntsman(iClient))
		return Plugin_Continue;

	if ((iButtons & IN_ATTACK2) && !(g_iLastButtons[iClient] & IN_ATTACK2))
	{
		g_BouncyClients[iClient] = !g_BouncyClients[iClient]; // toggle
		PrintToChat(iClient, "%s[VSH] %sArrows Bounce: %s", 
			COLOR_OLIVE, COLOR_DEFAULT, g_BouncyClients[iClient] ? "ON" : "OFF");
	}

	// Store current button state for next frame
	g_iLastButtons[iClient] = iButtons;

	return Plugin_Continue;
}

public void OnClientDisconnect(int iClient) 
{
	g_BouncyClients[iClient] = 0;
}

public void OnClientPutInServer(int iClient) 
{
	g_BouncyClients[iClient] = GetConVarInt(g_CvarDefaultBounceState);
	SDKHook(iClient, SDKHook_OnTakeDamage, OnTakeDamage);
}

public Action OnTakeDamage(int iVictim, int &iAttacker, int &iInflictor, 
													 float &iDamage, int &iDamagetype)
{
	if (iInflictor <= MaxClients || !IsValidEntity(iInflictor))
		return Plugin_Continue;

	int iRef = EntIndexToEntRef(iInflictor);
	int iEntity = FindEntityByRef(iRef);
	if (iEntity != -1)
	{
		int iData[ARRAY_ENTITY_SIZE];
		g_ModifiedEntities.GetArray(iEntity, iData);

		if (iData[EntityData_Enabled]) 
		{
			int iBounces = iData[EntityData_Bounces];
			float flMultiplier = Pow(1.55, float(iBounces));
			iDamage *= flMultiplier;

			PrintToChatAll("%s[VSH] %s%N %sjust %sTRICKSHOT x%d %s%N",
				COLOR_OLIVE, COLOR_RED, iAttacker, COLOR_DEFAULT, COLOR_YELLOW, iBounces, 
				COLOR_BLUE, iVictim, COLOR_DEFAULT);
		}
	}

	return Plugin_Changed;
}

void RemoveProjectilesByOwner(int iOwner)
{
	if (!IsValidClient(iOwner))
		return;

	int iData[ARRAY_ENTITY_SIZE];

	// Iterate backwards to safely remove while iterating
	for (int i = g_ModifiedEntities.Length - 1; i >= 0; i--)
	{
		g_ModifiedEntities.GetArray(i, iData);
		int iEntity = EntRefToEntIndex(iData[EntityData_EntityRef]);
		if (iEntity > MaxClients && IsValidEntity(iEntity))
		{
			int iEntityOwner = GetEntPropEnt(iEntity, Prop_Send, "m_hOwnerEntity");
			if (iEntityOwner == iOwner)
			{
				// Erase = remove entry at index
				g_ModifiedEntities.Erase(i);
			}
		}
		else
		{
			// Remove invalid entries too
			g_ModifiedEntities.Erase(i);
		}
	}
}

public void OnEntityCreated(int iEntity, const char[] sClassname) 
{
	if (strcmp(sClassname, "tf_projectile_arrow") == 0 && 
		(iEntity > MaxClients && IsValidEntity(iEntity))) 
	{
		RequestFrame(Frame_HandleProjectile, iEntity);	
	}
}

public void Frame_HandleProjectile(int iProjectile) 
{
	int owner = GetEntPropEnt(iProjectile, Prop_Send, "m_hOwnerEntity");
	if (!IsValidClient(owner)) 
		return;

	// Cleanup
	RemoveProjectilesByOwner(owner);
	//DEBUG: PrintToChatAll("Size: %i", g_ModifiedEntities.Length - 1);

	int iData[ARRAY_ENTITY_SIZE];
	iData[EntityData_EntityRef] = EntIndexToEntRef(iProjectile);
	iData[EntityData_Enabled] = 0;
	iData[EntityData_Bounces] = 0;

	if (g_BouncyClients[owner] == 1 
		&& g_ModifiedEntities.Length <= GetConVarInt(g_CvarMaxProjectiles)) 
	{
		float delay = GetConVarFloat(g_CvarTimeToStartBouncing);
		if (delay <= 0.0) 
		{
			iData[EntityData_Enabled] = 1;
		} 
		else 
		{
			CreateTimer(delay, Timer_EnableBouncy, iData[EntityData_EntityRef]);
		}

		g_ModifiedEntities.PushArray(iData);
		SDKHook(iProjectile, SDKHook_StartTouch, OnStartTouch);
	}
}

public Action Timer_EnableBouncy(Handle hTimer, int iRef) 
{
	int iEntity = FindEntityByRef(iRef);
	if (iEntity != -1) 
	{
		int iData[ARRAY_ENTITY_SIZE];
		g_ModifiedEntities.GetArray(iEntity, iData);
		iData[EntityData_Enabled] = 1;
		g_ModifiedEntities.SetArray(iEntity, iData);
	}
	return Plugin_Handled;
}

public Action OnStartTouch(int iProjectile, int iVictim) 
{
	int iRef = EntIndexToEntRef(iProjectile);
	int iEntity = FindEntityByRef(iRef);
	if (iEntity == -1) 
		return Plugin_Continue;

	int iData[ARRAY_ENTITY_SIZE];
	g_ModifiedEntities.GetArray(iEntity, iData);
	
	if (!iData[EntityData_Enabled] || iData[EntityData_Bounces] >= GetConVarInt(g_CvarMaxBounces) - 1) 
	{
		iData[EntityData_Bounces]++;
		g_ModifiedEntities.SetArray(iEntity, iData);
		return Plugin_Continue;
	}

	iData[EntityData_Bounces]++;
	g_ModifiedEntities.SetArray(iEntity, iData);
	SDKHook(iProjectile, SDKHook_Touch, OnTouch);
	return Plugin_Handled;
}

public Action OnTouch(int iProjectile, int iWall) 
{
	// If Client we Unhook
	if (IsValidClient(iWall))
	{
		SDKUnhook(iProjectile, SDKHook_Touch, OnTouch);
		return Plugin_Continue;
	}

	// Bounce logic only for geometry
	float flOrigin[3], flAngles[3], flVelocity[3];
	GetEntPropVector(iProjectile, Prop_Data, "m_vecOrigin", flOrigin);
	GetEntPropVector(iProjectile, Prop_Data, "m_angRotation", flAngles);
	GetEntPropVector(iProjectile, Prop_Data, "m_vecAbsVelocity", flVelocity);

	Handle hTrace = TR_TraceRayFilterEx(flOrigin, flAngles, MASK_SHOT, 
																		 RayType_Infinite, TraceFilter_GeometryOnly, 
																		 iProjectile);
	if (!TR_DidHit(hTrace)) 
	{
		CloseHandle(hTrace);
		return Plugin_Continue;
	}

	float flNormal[3];
	TR_GetPlaneNormal(hTrace, flNormal);
	CloseHandle(hTrace);

	float flDot = GetVectorDotProduct(flNormal, flVelocity);
	ScaleVector(flNormal, 2.0 * flDot);

	float flBounceVec[3];
	SubtractVectors(flVelocity, flNormal, flBounceVec);

	float flNewAngles[3];
	GetVectorAngles(flBounceVec, flNewAngles);
	TeleportEntity(iProjectile, NULL_VECTOR, flNewAngles, flBounceVec);

	SDKUnhook(iProjectile, SDKHook_Touch, OnTouch);
	return Plugin_Handled;
}

public bool TraceFilter_GeometryOnly(int iEntity, int iMask, any iProjectile)
{
	if (iEntity == iProjectile || IsValidClient(iEntity))
		return false;
	return true;
}

stock int FindEntityByRef(int iRef) 
{
	int iData[ARRAY_ENTITY_SIZE];
	for (int i = 0; i < g_ModifiedEntities.Length; i++) 
	{
		g_ModifiedEntities.GetArray(i, iData);
		if (iData[EntityData_EntityRef] == iRef) 
		{
			return i;
		}
	}
	return -1;
}

stock bool IsValidClient(int iClient) 
{
	return (iClient >= 1 && iClient <= MaxClients && IsClientInGame(iClient));
}

stock bool IsHoldingHuntsman(int iClient) 
{
  int iWeapon = GetEntPropEnt(iClient, Prop_Send, "m_hActiveWeapon");
  if (iWeapon > MaxClients && IsValidEntity(iWeapon)) 
  {
    int iIndex = GetEntProp(iWeapon, Prop_Send, "m_iItemDefinitionIndex");
    return iIndex == HUNTSMAN || iIndex == FESTIVE || iIndex == COMPOUND;
  }
  return false;
}