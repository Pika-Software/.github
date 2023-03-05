Plugin.Name = 'Discord RPC'
Plugin.Author = 'Pika Software'
Plugin.Description = 'A plugin for sending game session information to Discord.'

atmosphere.Require( 'gamemode' )
atmosphere.Require( 'discord' )
atmosphere.Require( 'loading' )
atmosphere.Require( 'convars' )
atmosphere.Require( 'console' )
atmosphere.Require( 'server' )
atmosphere.Require( 'steam' )
atmosphere.Require( 'utils' )
atmosphere.Require( 'api' )

local gamemode = atmosphere.gamemode
local discord = atmosphere.discord
local convars = atmosphere.convars
local console = atmosphere.console
local server = atmosphere.server
local steam = atmosphere.steam
local logger = discord.Logger
local api = atmosphere.api
local hook = hook

-- Presets
local function steamInfo()
    local clientInfo = steam.GetClientInfo()
    if clientInfo and clientInfo.steamid then
        steam.GetUser( steam.IDTo64( clientInfo.steamid ) ):Then( function( result )
            discord.SetupIcon( result.nickname, result.avatar )
        end )
    end
end

local function menuInfo( title, logo )
    if (title ~= discord.GetTitle()) then
        discord.StartTimeInGame()
    end

    discord.SetupImage( title, logo )
    discord.SetTitle( title )

    steamInfo()
end

local function mainMenu()
    menuInfo( 'atmosphere.mainmenu', 'clouds' )
end

-- Discord Connect Managment
do

    local timer = timer
    local attempts = 1

    local function connect()
        if discord.IsConnected() then return end
        logger:Info( 'Searching for a client...' )

        local code = discord.Init( '1016151516761030717' )
        if (code == 0) then
            attempts = 1
            return
        end

        local delay = attempts * 2
        timer.Create( 'atmoshere.discord.rpc.reconnect', delay, 1, connect )
        logger:Warn( 'Client disconnected (Code: %s), next attempt after %s sec.', code, delay )
        attempts = math.Clamp( attempts + 1, 1, 15 )
    end

    hook.Add( 'DiscordConnected', Plugin.Name, function()
        timer.Remove( 'atmoshere.discord.rpc.reconnect' )
        logger:Info( 'Client successfully connected.' )
    end )

    hook.Add( 'DiscordDisconnected', Plugin.Name, function()
        timer.Create( 'atmoshere.discord.rpc.reconnect', 0.25, 1, connect )
        logger:Warn( 'Client disconnected, reconnecting...' )
    end )

    hook.Add( 'DiscordReady', Plugin.Name, function()
        discord.Update()
    end )

    hook.Add( 'DiscordLoaded', Plugin.Name, function()
        connect()
        mainMenu()
    end )

end

-- Loading Info
hook.Add( 'LoadingStarted', Plugin.Name, function()
    discord.Clear()
    discord.StartTimeInGame()
    discord.SetImage( 'no_icon' )
    discord.SetImageText( 'unknown' )
    discord.SetState( 'atmosphere.connecting_to_server' )
end )

hook.Add( 'LoadingFinished', Plugin.Name, function()
    if server.IsConnected() then return end
    discord.Clear()
    mainMenu()
end )

local loadingStatus = convars.Create( 'discord_loading_status', true, TYPE_BOOL, ' - Displays the connection process in your Discord activity.', true )
hook.Add( 'LoadingStatusChanged', Plugin.Name, function( status )
    if not loadingStatus:GetValue() then return end
    if server.IsConnected() then return end
    discord.SetTitle( status )
end )

-- Game Info
hook.Add( 'ServerDetails', Plugin.Name, function( result )
    discord.SetImageText( result.Map )

    api.GameTrackerMapIcon( result.Map ):Then( function( url )
        discord.SetImage( url )
    end, function()
        discord.SetImage( 'no_icon' )
    end )

    if loadingStatus:GetValue() then return end
    discord.SetState( gamemode.GetName( result.Gamemode ) )
    discord.SetTitle( result.Name )
end )

local serverInfo = server.ServerInfo

do

    local string = string
    local util = util

    hook.Add( 'ClientConnected', Plugin.Name, function()
        steamInfo()

        discord.SetState( gamemode.GetName( Either( serverInfo.Gamemode == nil, engine.ActiveGamemode(), serverInfo.Gamemode ) ) )
        discord.SetTitle( server.GetHostName() )
        discord.SetImageText( serverInfo.Map )
        discord.StartTimeInGame()

        api.GameTrackerMapIcon( serverInfo.Map ):Then( function( url )
            discord.SetImage( url )
        end, function()
            discord.SetImage( 'gm_construct' )
        end )

        local secret = { server.GetAddress() }
        if (secret[ 1 ] == 'loopback') then
            local sid64 = serverInfo.SteamID64
            if not sid64 then sid64 = steam.IDTo64( steam.GetClientInfo().steamid ) end

            secret[ 1 ] = 'p2p:' .. sid64
            secret[ 3 ] = cvars.String( 'sv_password' )
            secret[ 2 ] = util.GetUUID()
        elseif server.IsP2P( secret[ 1 ] ) then
            secret[ 2 ] = discord.GetPartyID() or util.GetUUID()
            secret[ 3 ] = cvars.String( 'password' )
        else
            secret[ 2 ] = string.format( '%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x', string.byte( secret[ 1 ], 1, 16 ) )
            secret[ 3 ] = cvars.String( 'password' )
        end

        discord.SetJoinSecret( util.Base64Encode( table.concat( secret, ';' ) ) )
        discord.SetPartyID( secret[ 2 ] )
    end )

    hook.Add( 'DiscordJoin', Plugin.Name, function( joinSecret )
        local secret = util.Base64Decode( joinSecret )
        if not secret then return end

        local secretData = string.Split( secret, ';' )
        if (#secretData < 1) then return end

        local address = secretData[ 1 ]
        if not address then return end

        local partyID = secretData[ 2 ]
        if (partyID ~= nil) then
            discord.SetPartyID( partyID )

            local password = secretData[ 3 ]
            if (password ~= nil and password ~= '') then
                console.Run( 'password', password )
            end
        end

        discord.Logger:Info( 'Connecting to %s', address )
        server.Join( address )
    end )

end

do

    local serverDelay = convars.Create( 'discord_server_delay', 3, TYPE_NUMBER, ' - Time interval between server information updates.', true, 1, 120 )
    local CurTime = CurTime
    local nextUpdate = 0

    hook.Add( 'Think', Plugin.Name, function()
        if not server.IsConnected() then return end

        local time = CurTime()
        if (nextUpdate > time) then return end
        nextUpdate = time + serverDelay:GetValue()

        discord.SetPartySize( server.GetPlayerCount(), serverInfo.MaxPlayers )
        discord.SetTitle( server.GetHostName() )
    end )

end

hook.Add( 'ClientDisconnected', Plugin.Name, function()
    discord.Clear()
    mainMenu()
end )
