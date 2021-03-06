@Files = FileCollection
  resumable: true
  resumableIndexName: 'files'
  http: [
    method: 'get'
    path: '/id/:_id'
    lookup: (params, query) ->
      _id: params._id
  ]

fileUrlPrefix = "#{Files.baseURL}/id/"
@urlToFile = (id) ->
  id = id._id if id._id?
  "#{fileUrlPrefix}#{id}"
@url2file = (url) ->
  if url[...fileUrlPrefix.length] == fileUrlPrefix
    url[fileUrlPrefix.length..]
  else
    throw new Meteor.Error 'url2file.invalid',
      "Bad file URL #{url}"

@findFile = (id) ->
  Files.findOne new Meteor.Collection.ObjectID id
@deleteFile = (id) ->
  Files.remove new Meteor.Collection.ObjectID id

@fileType = (file) ->
  file = findFile file unless file.contentType?
  if file.contentType[...6] == 'image/'
    'image'
  else if file.contentType in ['video/mp4', 'video/ogg', 'video/webm']
    'video'
  else
    'unknown'

if Meteor.isServer
  @readableFiles = (userid) ->
    Files.find
      'metadata._Resumable': $exists: false
      #$or:
      #  'metadata.updator': @userId
      'metadata.group': $in: readableGroupNames userid

  Meteor.publish 'files', (userId) ->
    ## This prevents a race condition on the client between Meteor.userId() and subscriptions to this publish
    ## See: https://stackoverflow.com/questions/24445404/how-to-prevent-a-client-reactive-race-between-meteor-userid-and-a-subscription/24460877#24460877
    if @userId is userId
      @autorun => readableFiles @userId
    else
      @ready()

  Files.allow
    insert: (userId, file) ->
      file.metadata = {} unless file.metadata?
      check file.metadata,
        group: Match.Optional String
      file.metadata.uploader = userId
      groupRoleCheck file.metadata.group ? wildGroup, 'post'
    remove: (userId, file) ->
      file.metadata?.uploader in [userId, null]
    read: (userId, file) ->
      file.metadata?.uploader in [userId, null] or
      groupRoleCheck file.metadata?.group, 'read', findUser userId
    write: (userId, file, fields) ->
      file.metadata?.uploader in [userId, null]
else
  Tracker.autorun ->
    Meteor.subscribe 'files', Meteor.userId()
    $.cookie 'X-Auth-Token', Accounts._storedLoginToken(),
      path: '/'

  Session.set 'uploading', {}
  updateUploading = (changer) =>
    uploading = Session.get 'uploading'
    changer.call uploading
    Session.set 'uploading', uploading

  Files.resumable.on 'fileAdded', (file) =>
    updateUploading -> @[file.uniqueIdentifier] =
      filename: file.fileName
      progress: 0
    Files.insert
      _id: file.uniqueIdentifier    ## This is the ID resumable will use.
      filename: file.fileName
      contentType: file.file.type
      metadata:
        group: file.file.group
    , (err, _id) =>
      if err
        console.error "File creation failed:", err
      else
        ## Once the file exists on the server, start uploading.
        Files.resumable.upload()  ## xxx couldn't this upload the wrong file(s)?

  Files.resumable.on 'fileProgress', (file) =>
    updateUploading -> @[file.uniqueIdentifier].progress = Math.floor 100*file.progress()
  Files.resumable.on 'fileSuccess', (file) ->
    updateUploading -> delete @[file.uniqueIdentifier]
    if _.keys(Session.get 'uploading').length == 0
      window.dispatchEvent new Event 'filesDone'
    file.file.callback?(file)
  Files.resumable.on 'fileError', (file) ->
    console.error "Error uploading", file.uniqueIdentifier
    updateUploading -> delete @[file.uniqueIdentifier]
