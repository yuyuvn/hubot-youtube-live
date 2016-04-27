{Adapter, TextMessage} = require 'hubot'

params =
  clientId: process.env.YOUTUBE_CLIENT_ID
  clientSecret: process.env.YOUTUBE_CLIENT_SECRET
  redirect: process.env.YOUTUBE_REDIRECT || "http://localhost"
  rate: process.env.YOUTUBE_RATE || 3000
  code: process.env.YOUTUBE_OAUTH2_REFRESH_TOKEN
  scope: ['https://www.googleapis.com/auth/youtube',
    'https://www.googleapis.com/auth/youtube.force-ssl',
    'https://www.googleapis.com/auth/youtube.readonly']

google = require('googleapis')
oauth2Client = new google.auth.OAuth2 params.clientId, params.clientSecret, params.redirect

class Youtube extends Adapter
  constructor: (@robot) ->
    super @robot

  send: (envelope, strings...) ->
    for str in strings
      @api.insert envelope.room, str, (err) => @robot.logger.error err if err?

  reply: (envelope, strings...) ->
    name = envelope.user.name
    @send envelope, strings.map((str) -> "@#{name} #{str}")...

  run: ->
    @api = new YoutubeChat
    @api.login params.code, (err) =>
      return @robot.logger.error err if err?
      @emit "connected"

      @api.listen (err, chat) =>
        return @robot.logger.error err if err?
        return unless chat.snippet.type == "textMessageEvent"

        user = @robot.brain.userForId chat.snippet.authorChannelId,
          room: chat.snippet.liveChatId
          name: chat.authorDetails.displayName
        text = chat.snippet.textMessageDetails.messageText
        @robot.logger.debug "#{user.name}[#{user.room}]: #{text}"
        @receive new TextMessage user, text, chat.id

class YoutubeChat
  getLiveChat: (broadcast_id, pageToken=null, cb) ->
    [cb, pageToken] = [pageToken, null] unless cb?

    filter =
      part: "id,authorDetails,snippet"
      fields: "items(authorDetails/displayName,id,snippet),nextPageToken"
      liveChatId: broadcast_id
      maxResults: 2000
    filter.pageToken = pageToken if pageToken?

    @youtube.liveChatMessages.list filter, (err, response) =>
      return cb(err) if err?

      for item in response.items
        date = new Date(item.snippet.publishedAt)
        continue if @broadcasts[broadcast_id].lastPublished? and @broadcasts[broadcast_id].lastPublished >= date
        cb err, item if item.snippet.authorChannelId != @bot_channel
      if response.nextPageToken?
        setTimeout () =>
          @getLiveChat broadcast_id, response.nextPageToken, cb
        , params.rate


  getBroadcastList: (pageToken=null, cb) ->
    [cb, pageToken] = [pageToken, null] unless cb?

    filter =
      part: "snippet"
      fields: "items/snippet/liveChatId,nextPageToken"
      broadcastType: "all"
      maxResults: 50
    if process.env.HUBOT_YOUTUBE_FILTER_IDS?
      filter.id = process.env.HUBOT_YOUTUBE_FILTER_IDS
    else if process.env.HUBOT_YOUTUBE_FILTER_STATUS?
      filter.broadcastStatus = process.env.HUBOT_YOUTUBE_FILTER_STATUS
    else
      filter.mine = true
    filter.pageToken = pageToken if pageToken?

    @youtube.liveBroadcasts.list filter, (err, response) =>
      return cb(err) if err?

      return unless response.items?
      for item in response.items
        item = item.snippet
        @broadcasts[item.liveChatId] = lastPublished: new Date() if item.liveChatId?
      if response.nextPageToken?
        setTimeout () =>
          @getBroadcastList response.nextPageToken, cb
        , params.rate
      else
        cb()

  login: (token, cb) ->
    oauth2Client.setCredentials refresh_token: token
    @youtube = google.youtube
      version: 'v3'
      auth: oauth2Client

    @youtube.channels.list part: "id", mine: true, (err, res) =>
      return cb(err) if err?
      @bot_channel = res.items[0].id if res.items? and res.items[0]?
      @broadcasts = []
      @getBroadcastList cb

  listen: (cb) ->
    for broadcast_id in Object.keys @broadcasts
      @getLiveChat broadcast_id, cb

  insert: (broadcast, message, cb) ->
    body = snippet:
      liveChatId: broadcast
      type: "textMessageEvent"
      textMessageDetails: messageText: message
    @youtube.liveChatMessages.insert part: "snippet", resource: body, cb

exports.use = (robot) ->
  new Youtube robot
