#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <webcon>

#define BASE_PATH "configs/web/sprayviewer/"

WebResponse webIndex;
WebResponse webStyle;
WebResponse webVTFlib;
WebResponse webNotFound;

ConVar cvarSprayURL;

public void OnPluginStart()
{
	// Setup webcon
	if (!Web_RegisterRequestHandler("sprayviewer", OnWebRequest, "Spray Viewer", "View the sprays of in-game players"))
		SetFailState("Failed to register request handler.");
	
	char path[PLATFORM_MAX_PATH];
	
	BuildPath(Path_SM, path, sizeof(path), BASE_PATH ... "index.html");
	webIndex = new WebFileResponse(path);
	webIndex.AddHeader(WebHeader_ContentType, "text/html; charset=UTF-8");
	
	BuildPath(Path_SM, path, sizeof(path), BASE_PATH ... "style.css");
	webStyle = new WebFileResponse(path);
	webStyle.AddHeader(WebHeader_ContentType, "text/css");
	webStyle.AddHeader(WebHeader_CacheControl, "public, max-age=2629740");
	
	BuildPath(Path_SM, path, sizeof(path), BASE_PATH ... "vtflib.js");
	webVTFlib = new WebFileResponse(path);
	webVTFlib.AddHeader(WebHeader_ContentType, "text/javascript");
	webVTFlib.AddHeader(WebHeader_CacheControl, "public, max-age=2629740");
	
	webNotFound = new WebStringResponse("404 Not Found");
	
	// Auto-detect the URL for displaying in the MotD
	int hostip = GetConVarInt(FindConVar("hostip"));
	int hostport = GetConVarInt(FindConVar("hostport"));
	
	char sIP[32];
	LongToIP(hostip, sIP, sizeof(sIP));
	
	char sURL[128];
	FormatEx(sURL, sizeof(sURL), "http://%s:%u/sprayviewer/", sIP, hostport);
	
	// Might be wrong, make it configurable
	cvarSprayURL = CreateConVar("web_sprayviewer_url", sURL, "The URL used by the sm_sprayviewer command.");
	
	RegConsoleCmd("sm_sprayviewer", Command_SprayViewer);
}

public Action Command_SprayViewer(int client, int args)
{
	char sURL[128];
	cvarSprayURL.GetString(sURL, sizeof(sURL));
	
	if (client)
	{
		KeyValues kv = new KeyValues("data");
		
		kv.SetString("title", "Spray Viewer");
		kv.SetString("type", "2"); // MOTDPANEL_TYPE_URL
		kv.SetString("msg", sURL);
		kv.SetNum("unload", 1); // unload the page when closed
		
		if (GetEngineVersion() == Engine_TF2)
			kv.SetNum("customsvr", 1); // use the larger window
		
		ShowVGUIPanel(client, "info", kv);
		
		delete kv;
	}
	else
	{
		PrintToServer("Spray Viewer URL (web_sprayviewer_url): %s", sURL);
	}
	
	return Plugin_Handled;
}

public bool OnWebRequest(WebConnection connection, const char[] method, const char[] url)
{
	if (StrEqual(url, "/players"))
	{
		static int lastDataGeneration;
		static WebResponse dataResponse;
		
		int time = GetTime();
		
		if (dataResponse != null && (time - lastDataGeneration) < 5)
			return connection.QueueResponse(WebStatus_OK, dataResponse);
		
		// char numplayers (1)
		// array (MAXPLAYERS)
		//  - uint serial (4)
		//  - uint accountid (4)
		//  - string name (32 + 1)
		
		char buffer[1 + ((4 + 4 + 32 + 1) * (MAXPLAYERS))];
		char temp[1];
		int length = 1; // skip numplayers until later
		int numPlayers = 0;
		
		for (int i = 1; i <= MaxClients; i++)
		{
			if (!IsClientInGame(i) || !GetPlayerDecalFile(i, temp, 0))
				continue;
			
			length += WriteBytes(buffer[length], sizeof(buffer) - length, GetClientSerial(i), 4);
			length += WriteBytes(buffer[length], sizeof(buffer) - length, GetSteamAccountID(i, false), 4);
			length += FormatEx(buffer[length], sizeof(buffer) - length, "%N", i) + 1;
			
			numPlayers++;
		}
		
		WriteBytes(buffer, sizeof(buffer), numPlayers, 1);
		
		if (length > sizeof(buffer))
		{
			LogError("Buffer size mismatch: %d > %d", length, sizeof(buffer));
			return false;
		}
		
		lastDataGeneration = time;
		
		delete dataResponse;
		dataResponse = new WebBinaryResponse(buffer, length);
		dataResponse.AddHeader(WebHeader_ContentType, "application/octet-stream");
		dataResponse.AddHeader(WebHeader_CacheControl, "public, max-age=5");
		
		return connection.QueueResponse(WebStatus_OK, dataResponse);
	}
	
	// Doing client serial <-> spray conversion so we only serve online player sprays
	if (strncmp(url, "/spray/", 7) == 0)
	{
		int serial = StringToInt(url[7], 16);
		if (!serial)
			return connection.QueueResponse(WebStatus_NotFound, webNotFound);
		
		int client = GetClientFromSerial(serial);
		if (!client)
			return connection.QueueResponse(WebStatus_NotFound, webNotFound);
		
		char sSprayHex[10];
		if (!GetPlayerDecalFile(client, sSprayHex, sizeof(sSprayHex)))
			return connection.QueueResponse(WebStatus_NotFound, webNotFound);
		
		char sSprayPath[PLATFORM_MAX_PATH];
		FormatEx(sSprayPath, sizeof(sSprayPath), "download/user_custom/%02.2s/%08.8s.dat", sSprayHex, sSprayHex);
		
		if (!FileExists(sSprayPath))
		{
			FormatEx(sSprayPath, sizeof(sSprayPath), "downloads/%08.8s.dat", sSprayHex);
			
			if (!FileExists(sSprayPath))
				return connection.QueueResponse(WebStatus_NotFound, webNotFound);
		}
		
		WebResponse sprayResponse = new WebFileResponse(sSprayPath);
		sprayResponse.AddHeader(WebHeader_ContentType, "application/octet-stream");
		sprayResponse.AddHeader(WebHeader_CacheControl, "public, max-age=30");
		bool success = connection.QueueResponse(WebStatus_OK, sprayResponse);
		
		delete sprayResponse;
		
		return success;
	}

	if (StrEqual(url, "/"))
		return connection.QueueResponse(WebStatus_OK, webIndex);
	if (StrEqual(url, "/style.css"))
		return connection.QueueResponse(WebStatus_OK, webStyle);
	if (StrEqual(url, "/vtflib.js"))
		return connection.QueueResponse(WebStatus_OK, webVTFlib);

	return connection.QueueResponse(WebStatus_NotFound, webNotFound);
}

int LongToIP(int ip, char[] buffer, int maxlength)
{
	return FormatEx(buffer, maxlength, "%d.%d.%d.%d", (ip >> 24) & 0xFF, (ip >> 16) & 0xFF, (ip >> 8) & 0xFF, ip & 0xFF);
}

int WriteBytes(char[] buffer, int maxlength, int value, int numbytes)
{
	if (maxlength < numbytes)
		return 0;
	
	for (int i = 0; i < numbytes; i++)
	{
		buffer[i] = (value >> (i * 8)) & 0xFF;
	}

	return numbytes;
}
