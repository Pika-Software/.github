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

local function steamInfo()
    local clientInfo = steam.GetClientInfo()
    if clientInfo and clientInfo.steamid then
        steam.GetUser( steam.IDTo64( clientInfo.steamid ) ):Then( function( result )
            discord.SetupIcon( result.nickname, result.avatar )
        end)
    end
end

local function menuInfo( title, logo )
    -- Time in menu
    if (title ~= discord.GetTitle()) then
        discord.StartTimeInGame()
    end

    -- Menu Info
    discord.SetTitle( title )
    discord.SetupImage( title, logo )

    steamInfo()
end

local function mainMenu()
    menuInfo( 'atmosphere.mainmenu', 'clouds' )
end

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

-- Loading Status Feature
local loadingStatus = convars.Create( 'discord_loading_status', false, TYPE_BOOL, ' - Displays the connection process in your Discord activity.', true )
hook.Add( 'LoadingStatusChanged', Plugin.Name, function( status )
    if not loadingStatus:GetValue() then return end
    discord.SetTitle( status )
end )

-- Server Info
local serverData = server.ServerData

hook.Add( 'ServerDetails', Plugin.Name, function( result )
    discord.SetState( gamemode.GetName( result.Gamemode ) )
    discord.SetPartySize( 1, result.MaxPlayers )
    discord.SetImageText( result.Map )

    if not loadingStatus:GetValue() then
        discord.SetTitle( result.Name )
    end

    api.GameTrackerMapIcon( result.Map ):Then( function( url )
        discord.SetImage( url )
    end,
    function()
        discord.SetImage( 'gm_construct' )
    end )
end )

hook.Add( 'ServerInfo', Plugin.Name, function( result )
    discord.SetPartySize( result.HumanCount, result.MaxPlayers )
    discord.SetState( gamemode.GetName( result.Gamemode ) )
    discord.SetImageText( result.Map )

    if not loadingStatus:GetValue() then
        discord.SetTitle( result.Name )
    end

    api.GameTrackerMapIcon( result.Map ):Then( function( url )
        discord.SetImage( url )
    end,
    function()
        discord.SetImage( 'gm_construct' )
    end )

    steamInfo()
end )

hook.Add( 'LoadingStarted', Plugin.Name, function()
    discord.SetTitle( 'atmosphere.connecting_to_server' )
    discord.StartTimeInGame()
end )

hook.Add( 'Disconnected', Plugin.Name, function()
    discord.Clear()
    mainMenu()
end )

do

    local string = string
    local util = util

    hook.Add( 'LoadingFinished', Plugin.Name, function()
        discord.SetState( gamemode.GetName( serverData.Gamemode or 'unknown' ) )
        discord.SetTitle( serverData.Name or 'unknown' )
        discord.StartTimeInGame()
        steamInfo()

        if server.IsLocalHost() then
            local clientInfo = steam.GetClientInfo()
            if not clientInfo or not clientInfo.steamid then return end

            discord.SetJoinSecret( util.Base64Encode( string.format( 'p2p:%s;%s', steam.IDTo64( clientInfo.steamid ), cvars.String( 'sv_password', '' ) ) ) )
            discord.SetPartyID( util.UUID() )
            return
        end

        local address = server.GetAddress()
        discord.SetJoinSecret( util.Base64Encode( address .. ';' .. cvars.String( 'password', '' ) ) )
        discord.SetPartyID( string.format( '%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x', string.byte( address, 1, 16 ) ) )
    end )

    hook.Add( 'DiscordJoin', Plugin.Name, function( joinSecret )
        local secret = util.Base64Decode( joinSecret )
        if not secret then return end

        local secretData = string.Split( secret, ';' )
        if (#secretData < 1) then return end

        local address = secretData[1]
        if not address then return end

        local password = secretData[2]
        if (password ~= nil and password ~= '') then
            console.Run( 'password', password )
        end

        discord.Logger:Info( 'Connecting to %s', address )
        server.Join( address )
    end )

end

do

    local serverDelay = convars.Create( 'discord_server_delay', 10, TYPE_NUMBER, ' - Time interval between server information updates.', true, 5, 120 )
    local nextUpdate = 0

    hook.Add( 'Think', Plugin.Name, function()
        if not server.IsConnected() then return end

        local clientState = server.GetClientState()
        if (clientState >= 0 and clientState < 5 or clientState == 7) then return end

        if server.IsSinglePlayer() then return end

        local time = CurTime()
        if (nextUpdate > time) then return end
        nextUpdate = time + serverDelay:GetValue()

        if server.IsLocalHost() or server.IsP2P() then
            -- TODO: Need a method to get players count here
            discord.SetPartySize( 1, cvars.Number( 'maxplayers', 2 ) )
            discord.SetState( gamemode.GetName( cvars.String( 'gamemode', 'sandbox' ) ) )
            discord.SetTitle( cvars.String( 'hostname', 'Garry\'s Mod' ) )

            local mapName = serverData.Map or 'gm_construct'
            discord.SetImageText( mapName )

            api.GameTrackerMapIcon( mapName ):Then( function( url )
                discord.SetImage( url )
            end,
            function()
                discord.SetImage( 'gm_construct' )
            end )

            return
        end

        server.Get( server.GetAddress() ):Then( function( result )
            discord.SetPartySize( result.humans, result.maxplayers )
            discord.SetState( gamemode.GetName( result.gamemode ) )
            discord.SetImageText( result.map )
            discord.SetTitle( result.name )

            api.GameTrackerMapIcon( result.map ):Then( function( url )
                discord.SetImage( url )
            end,
            function()
                discord.SetImage( 'gm_construct' )
            end )
        end )
    end )
   
end
