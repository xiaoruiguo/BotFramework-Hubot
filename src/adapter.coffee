#
# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license.
#
# Microsoft Bot Framework: http://botframework.com
#
# Bot Builder SDK Github:
# https://github.com/Microsoft/BotBuilder
#

Util = require 'util'
Timers = require 'timers'

BotBuilder = require 'botbuilder'
{ Robot, Adapter, TextMessage, User } = require 'hubot'
Middleware = require './adapter-middleware'
MicrosoftTeamsMiddleware = require './msteams-middleware'

LogPrefix = "hubot-botframework-adapter:"

class BotFrameworkAdapter extends Adapter
    constructor: (robot) ->
        super robot
        @appId = process.env.BOTBUILDER_APP_ID
        @appPassword = process.env.BOTBUILDER_APP_PASSWORD       
        @endpoint = process.env.BOTBUILDER_ENDPOINT || "/api/messages"
        @enableAuth = process.env.HUBOT_TEAMS_ENABLE_AUTH || 'false'
        robot.logger.info "#{LogPrefix} Adapter loaded. Using appId #{@appId}"

        # Initial Admins should be required when auth is enabled or not set
        if @enableAuth == 'true'
            if process.env.HUBOT_TEAMS_INITIAL_ADMINS
                if robot.brain.get("authorizedUsers") is null
                    robot.logger.info "#{LogPrefix} Restricting by name, setting admins"
                    authorizedUsers = {}
                    for admin in process.env.HUBOT_TEAMS_INITIAL_ADMINS.split(",")
                        authorizedUsers[admin] = true
                    robot.brain.set("authorizedUsers", authorizedUsers)
            else
                throw new Error("HUBOT_TEAMS_INITIAL_ADMINS is required for authorization")

        @connector  = new BotBuilder.ChatConnector {
            appId: @appId
            appPassword: @appPassword
        }

        @connector.onEvent (events, cb) => @onBotEvents events, cb

        @connector.onInvoke (events, cb) => @sendTextToHubot events, cb

    sendTextToHubot: (invokeEvent, cb) ->
        console.log("In the invoke handler")
        invokeEvent.text = invokeEvent.value.hubotMessage
        delete invokeEvent.value
        console.log(invokeEvent)
        @handleActivity(invokeEvent)


    using: (name) ->
        MiddlewareClass = Middleware.middlewareFor(name)
        new MiddlewareClass(@robot)

    onBotEvents: (activities, cb) ->
        @robot.logger.info "#{LogPrefix} onBotEvents"
        activities = [activities] unless Array.isArray activities
        @handleActivity activity for activity in activities

    handleActivity: (activity) ->
        @robot.logger.info "#{LogPrefix} Handling activity Channel: #{activity.source}; type: #{activity.type}"
        console.log("The activity parameter:")
        console.log(JSON.stringify(activity, null, 2))

        # Construct the middleware
        middleware = @using(activity.source)

        # Drop the activity if the user cannot be authenticated with their
        # AAD Object Id or if the user is unauthorized
        authorizedUsers = @robot.brain.get("authorizedUsers")
        aadObjectId = activity?.address?.user?.aadObjectId
        if @enableAuth == 'true'
            if middleware.supportsAuth()
                if aadObjectId is undefined or authorizedUsers[aadObjectId] is undefined
                    @robot.logger.info "#{LogPrefix} Unauthorized user; returning error"
                    activity.text = "hubot return unauthorized user error"
            else
                @robot.logger.info "#{LogPrefix} Message source doesn't support authorization"
                activity.text = "hubot return source authorization not supported error"

        # If authorization isn't supported by the activity source, use
        # the text middleware
        if not middleware.supportsAuth()
            event = middleware.toReceivable activity
            if event?
                console.log("Hubot event, not callback:")
                console.log(event)

                @robot.receive event
        else
            middleware.toReceivable activity, (event) =>
                console.log("AFTER TO RECEIVABLE")
                console.log(event)
                if event?
                    console.log("Hubot event:")
                    console.log(event)

                    @robot.receive event

    send: (context, messages...) ->
        @robot.logger.info "#{LogPrefix} send"
        @reply context, messages...

    reply: (context, messages...) ->
        @robot.logger.info "#{LogPrefix} reply"
        for msg in messages
            activity = context.user.activity
            payload = @using(activity.source).toSendable(context, msg)

            if !Array.isArray(payload)
                payload = [payload]
            
            console.log("printing payload for reply: --------------------")
            console.log(JSON.stringify(payload, null, 2))
            @connector.send payload, (err, _) ->
                if err
                    console.log("THIS IS WHERE ITS THROWING THE ERROR")
                    throw err

    run: ->
        @robot.router.post @endpoint, @connector.listen()
        @robot.logger.info "#{LogPrefix} Adapter running."
        Timers.setTimeout (=> @emit "connected"), 1000

module.exports = {
    Middleware,
    MicrosoftTeamsMiddleware
}

module.exports.use = (robot) ->
    new BotFrameworkAdapter robot
