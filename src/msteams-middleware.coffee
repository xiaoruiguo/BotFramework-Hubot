#
# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license.
#
# Description:
#   Middleware to make Hubot work well with Microsoft Teams
#
# Configuration:
#	HUBOT_OFFICE365_TENANT_FILTER
#
# Commands:
#	None
#
# Notes:
#   1. Typing indicator support
#   2. Properly converts Slack @mentions to Teams @mentions
#   3. Properly handles chat vs. channel messages
#   4. Optionally filters out messages from outside the tenant
#   5. Properly handles image responses.
#
# Author:
#	billbliss
#

BotBuilder = require 'botbuilder'
BotBuilderTeams = require 'botbuilder-teams'
HubotResponseCards = require './hubot-response-cards'
#MicrosoftGraph = require '@microsoft/microsoft-graph-client'
{ Robot, TextMessage, Message, User } = require 'hubot'
{ BaseMiddleware, registerMiddleware } = require './adapter-middleware'
LogPrefix = "hubot-msteams:"

class MicrosoftTeamsMiddleware extends BaseMiddleware
    constructor: (@robot) ->
        super(@robot)

        @allowedTenants = []
        if process.env.HUBOT_OFFICE365_TENANT_FILTER?
            @allowedTenants = process.env.HUBOT_OFFICE365_TENANT_FILTER.split(",")
            @robot.logger.info("#{LogPrefix} Restricting tenants to #{JSON.stringify(@allowedTenants)}")

    toReceivable: (activity, cb) ->
        @robot.logger.info "#{LogPrefix} toReceivable"

        # Drop the activity if it came from an unauthorized tenant
        if @allowedTenants.length > 0 && !@allowedTenants.includes(getTenantId(activity))
            @robot.logger.info "#{LogPrefix} Unauthorized tenant; ignoring activity"
            return null

        # Get the user
        user = getUser(activity)
        user = @robot.brain.userForId(user.id, user)

        # We don't want to save the activity or room in the brain since its something that changes per chat.
        user.activity = activity
        user.room = getRoomId(activity)

        if activity.type != 'message' && activity.type != 'invoke'
            return new Message(user)
        else
            # Try to get chat members first then construct the message to send to hubot
            teamsConnector = new BotBuilderTeams.TeamsChatConnector {
                appId: @robot.adapter.appId
                appPassword: @robot.adapter.appPassword
            }
            teamsConnector.fetchMembers activity?.address?.serviceUrl, activity?.address?.conversation?.id, (err, result) =>
                if err
                    console.log("THERE WAS AN ERROR")
                    return

                activity = fixActivityForHubot(activity, @robot, result)
                message = new TextMessage(user, activity.text, activity.address.id)
                cb(message)

    toSendable: (context, message) ->
        @robot.logger.info "#{LogPrefix} toSendable"
        activity = context?.user?.activity

        response = message
        if typeof message is 'string'
            # Trim leading or ending whitespace
            response =
                type: 'message'
                text: message.trim()
                address: activity?.address

            # If the query sent by the user should trigger a card,
            # construct the card to attach to the response
            # and remove sentQuery from the brain
            card = HubotResponseCards.maybeConstructCard(response, activity.text)
            if card != null
                delete response.text
                response.attachments = [card]

            imageAttachment = convertToImageAttachment(message)

            if response.text == "List the admins"
                heroCard = new BotBuilder.HeroCard()
                heroCard.title('Teams Admins')
                
                authorizedUsers = @robot.brain.get("authorizedUsers")

                text = ""
                for user, isAdmin of authorizedUsers
                    if isAdmin
                        if text == ""
                            text = user
                        else
                            text = """#{text}
                                    #{user}"""
                text = escapeLessThan(text)
                text = escapeNewLines(text)
                heroCard.text(text)

                delete response.text
                response.attachments = [heroCard.toAttachment()]

            else if response.text == "unicorns"
                heroCard = new BotBuilder.HeroCard()

                button = new BotBuilder.CardAction.imBack()
                button.data.title ='Follow up'
                button.data.value = 'ping'

                image = new BotBuilder.CardImage().url("http://30.media.tumblr.com/tumblr_lisw5dD4Pu1qbbpjfo1_400.jpg")
                heroCard.images([image])
                heroCard.buttons([button])
                
                delete response.text
                response.attachments = [heroCard.toAttachment()]
            
            else if imageAttachment?
                delete response.text
                response.attachments = [imageAttachment]

        response = fixMessageForTeams(response, @robot)

        typingMessage =
          type: "typing"
          address: activity?.address

        return [typingMessage, response]
    
    # Indicates that the authorization is supported for this middleware (Teams)
    supportsAuth: () ->
        return true

    #############################################################################
    # Helper methods for generating richer messages
    #############################################################################

    imageRegExp = /^(https?:\/\/.+\/(.+)\.(jpg|png|gif|jpeg$))/

    # Generate an attachment object from the first image URL in the message
    convertToImageAttachment = (message) ->
        if not typeof message is 'string'
            return null

        result = imageRegExp.exec(message)
        if result?
            attachment =
                contentUrl: result[1]
                name: result[2]
                contentType: "image/#{result[3]}"
            return attachment

        return null
        
    # Fetches the user object from the activity
    getUser = (activity) ->
        user =
            id: activity?.address?.user?.id,
            name: activity?.address?.user?.name,
            tenant: getTenantId(activity)
            aadObjectId: getUserAadObjectId(activity)
        return user
    
    # Fetches the user's name from the activity
    getUserName = (activity) ->
        return activity?.address?.user?.name

    # Fetches the user's AAD Object Id from the activity
    getUserAadObjectId = (activity) ->
        return activity?.address?.user?.aadObjectId

    # Fetches the room id from the activity
    getRoomId = (activity) ->
        return activity?.address?.conversation?.id

    # Fetches the tenant id from the activity
    getTenantId = (activity) ->
        return activity?.sourceEvent?.tenant?.id

    # Returns the array of mentions that can be found in the message.
    getMentions = (activity, userId) ->
        entities = activity?.entities || []
        if not Array.isArray(entities)
            entities = [entities]
        return entities.filter((entity) -> entity.type == "mention" && (not userId? || userId == entity.mentioned?.id))

    # Fixes the activity to have the proper information for Hubot
    #  0. Constructs the text command to send to hubot if the event is from a
    #  submit on an adaptive card (containing the value property). 
    #  ***
    #  1. Replaces all occurrences of the channel's bot at mention name with the configured name in hubot.
    #  The hubot's configured name might not be the same name that is sent from the chat service in
    #  the activity's text.
    #  2. Replaces all occurrences of @ mentions to users with their aad object id if the user is
    #  on the roster of chanenl members from Teams. If a mentioned user is not in the chat roster,
    #  the mention is replaced with their name.
    #  3. Prepends hubot's name to the message if this is a direct message.
    fixActivityForHubot = (activity, robot, chatMembers) ->
        if activity?.value != undefined
            data = activity.value
            queryPrefix = data.queryPrefix
            console.log("********************")
            console.log(data)
            # Get the first command part. A command always begins with a text part
            # as commands always beging with the word 'hubot'
            text = data[queryPrefix + " - query0"]
            text = text.replace("hubot", robot.name)
            console.log(text)

            # If there are inputs, add those and the next query part
            # if there is one
            i = 0
            input = data[queryPrefix + " - input#{i}"]
            while input != undefined
                text = text + input
                nextTextPart = data[queryPrefix + " - query" + (i + 1)]
                if nextTextPart != undefined
                    text = text + nextTextPart
                i++
                input = data[queryPrefix + " - input#{i}"]
            console.log("CONSTRUCTING HUBOT TEXT QUERY")
            console.log(text)

            activity.text = text
            return activity

        if not activity?.text? || typeof activity.text isnt 'string'
            return activity
        myChatId = activity?.address?.bot?.id
        if not myChatId?
            return activity

        # Replace all @ mentions to the bot with the bot's name, and replace
        # all @ mentions of users with a known aad object id with their aad
        # object id.
        mentions = getMentions(activity)
        for mention in mentions
            mentionTextRegExp = new RegExp(escapeRegExp(mention.text), "gi")
            replacement = mention.mentioned.name
            if mention.mentioned.id == myChatId
                replacement = robot.name
            if chatMembers != undefined
                for member in chatMembers
                    if mention.mentioned.id == member.id
                        replacement = member.objectId
            activity.text = activity.text.replace(mentionTextRegExp, replacement)

        # prepends the robot's name for direct messages
        if not activity.text.startsWith(robot.name)
            activity.text = "#{robot.name} #{activity.text}"

        # Remove the newline character at the beginning or end of the text,
        # if there are any
        if activity.text.charAt(activity.text.length - 1) == '\n'
            activity.text = activity.text.trim()
            
        return activity

    slackMentionRegExp = /<@([^\|>]*)\|?([^>]*)>/g

    # Fixes the response to have the proper information that teams needs
    # 1. Replaces all slack @ mentions with Teams @ mentions
    #  Slack mentions take the form of <@[username or id]|[mention text]>
    #  We have to convert this into a mention object which needs the id.
    # Adds escapes for all < such as in the hubot help command
    fixMessageForTeams = (response, robot) ->
        if not response?.text?
            return response
        mentions = []
        while match = slackMentionRegExp.exec(response.text)
            foundUser = null
            users = robot.brain.users()
            for userId, user of users
                if userId == match[1] || user.name == match[1]
                    foundUser = user

            userId = foundUser?.id || match[1]
            userName = foundUser?.name || match[1]
            userText = "<at>#{match[2] || userName}</at>"
            mentions.push(
                full: match[0]
                mentioned:
                    id: userId
                    name: userName
                text: userText
                type: "mention")
        
        for mention in mentions
            mentionTextRegExp = new RegExp(escapeRegExp(mention.full), "gi")
            response.text = response.text.replace(mentionTextRegExp, mention.text)
            delete mention.full
        response.entities = mentions

        # Escape <
        if response.text.search("hubot") == 0
            response.text = escapeLessThan(response.text)

        # Replace new lines with <br>
        response.text = escapeNewLines(response.text)

        return response

    escapeRegExp = (str) ->
        return str.replace(/[\-\[\]\/\{\}\(\)\*\+\?\.\\\^\$\|]/g, "\\$&")

    escapeLessThan = (str) ->
        #str = str.replace(/</g, "`<")
        str = str.replace(/</g, "&lt;")
        #str = str.replace(/>/g, ">`")
        return str

    escapeNewLines = (str) ->
        return str.replace(/\n/g, "<br/>")

    # On call, we know that response.text is text
    constructHubotResponseCard = (activity) ->
        # Check if response.text matches any of the query templates

registerMiddleware 'msteams', MicrosoftTeamsMiddleware

module.exports = MicrosoftTeamsMiddleware
