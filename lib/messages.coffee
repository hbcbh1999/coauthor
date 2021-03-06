import { defaultFormat } from './settings.coffee'

@untitledMessage = '(untitled)'

@titleOrUntitled = (msg) ->
  unless msg?
    null
  else if not msg.title? or msg.title.trim().length == 0
    if msg.file and (file = findFile msg.file)
      file.filename
    else
      untitledMessage
  else
    msg.title

@Messages = new Mongo.Collection 'messages'
@MessagesDiff = new Mongo.Collection 'messages.diff'
@MessagesParent = new Mongo.Collection 'messages.parents'

@rootMessages = (group) ->
  query =
    root: null
  if group?
    query.group = group
  Messages.find query

_submessageCount = (root) ->
  root = root._id if root._id?
  Messages.find
    root: root
    published: $ne: false    ## published is false or Date
    deleted: $ne: true
    private: $ne: true
  .count()

_submessageLastUpdate = (root) ->
  root = Messages.findOne root unless root._id?
  return null unless root?
  updated = root.updated
  Messages.find
    root: root._id
    published: $ne: false    ## published is false or Date
    deleted: $ne: true
    private: $ne: true
  .forEach (submessage) ->
    updated = dateMax updated, submessage.updated
  updated

## Works from nonroot messages via recursion.  Doesn't include message itself.
@descendantMessageIds = (message) ->
  descendants = []
  recurse = (m) ->
    m = Messages.findOne m if _.isString m
    for child in m.children
      descendants.push child
      recurse child
  recurse message
  descendants

@accessibleMessagesQuery = (group, user = Meteor.user()) ->
  ## Mimic logic of `canSee` below.
  if groupRoleCheck group, 'super', user
    ## Super-user can see all messages, even unpublished/deleted messages.
    group: group
  else if groupRoleCheck group, 'read', user
    ## Regular users can see all messages they authored, plus
    ## published undeleted messages by others.
    if user?.username
      group: group
      $or: [
        published: $ne: false    ## published is false or Date
        deleted: $ne: true
        private: $ne: true
      ,
        "authors.#{escapeUser user.username}": $exists: true
      ,
        body: ///@#{user.username}\b///
      ]
    else
      group: group
      published: $ne: false    ## published is false or Date
      deleted: $ne: true
      private: $ne: true
  else
    null

if Meteor.isServer
  Meteor.publish 'messages.all', (group) ->
    check group, String
    @autorun ->
      query = accessibleMessagesQuery group, findUser @userId
      return @ready() unless query?
      Messages.find query

  Meteor.publish 'messages.imported', (group) ->
    check group, String
    @autorun ->
      query = accessibleMessagesQuery group, findUser @userId
      return @ready() unless query?
      query.imported = $ne: null
      Messages.find query

  Meteor.publish 'messages.root', (group) ->
    check group, String
    @autorun ->
      query = accessibleMessagesQuery group, findUser @userId
      return @ready() unless query?
      query.root = null
      Messages.find query

  Meteor.publish 'messages.submessages', (msgId) ->
    check msgId, String
    @autorun ->
      message = Messages.findOne msgId
      return @ready() unless message?.group?
      query = accessibleMessagesQuery message.group, findUser @userId
      return @ready() unless query?
      root = message.root ? msgId
      Messages.find
        $and: [query,
          $or: [
            _id: root
          , root: root
          ]
        ]

if Meteor.isServer
  ## Returns a query for the messages matching the given query (possibly
  ## with options) along with their roots.  Implicitly we are assuming that,
  ## if a message is accessible, then so is its root.  This is not technically
  ## true if the root is deleted/unpublished and not authored by the user,
  ## in which case we reveal the message to the user (but seems better than
  ## having a dangling root pointer...).
  addRootsToQuery = (query, options = {}) ->
    #options = _.clone options  ## avoid modifying caller's options
    options.fields = root: 1  ## just get (and depend on) root and _id
    messages = Messages.find query, options
    ids = {}
    messages.forEach (msg) ->
      ids[msg._id] = 1
      ids[msg.root] = 1 if msg.root?
    ids = _.keys ids  ## remove duplicates
    _id: $in: ids

@messagesByQuery = (group, author) ->
  query =
    group: group
    "authors.#{escapeUser author}": $exists: true
    published: $ne: false
    deleted: $ne: true
  if group == wildGroup
    delete query.group
  query

@messagesBy = (group, author) ->
  Messages.find messagesByQuery(group, author),
    sort: [['updated', 'desc']]
    #limit: parseInt(@limit)

if Meteor.isServer
  Meteor.publish 'messages.author', (group, author) ->
    check group, String
    check author, String
    @autorun ->
      query = accessibleMessagesQuery group, findUser @userId
      return @ready() unless query?
      query = $and: [
        query
        messagesByQuery wildGroup, author  ## no need to repeat group
      ]
      Messages.find addRootsToQuery query

@messagesTaggedQuery = (group, tag) ->
  query =
    group: group
    "tags.#{escapeTag tag}": $exists: true
    published: $ne: false
    deleted: $ne: true
  if group == wildGroup
    delete query.group
  query

@messagesTagged = (group, tag) ->
  Messages.find messagesTaggedQuery(group, tag),
    sort: [['updated', 'desc']]
    #limit: parseInt(@limit)

if Meteor.isServer
  Meteor.publish 'messages.tag', (group, tag) ->
    check group, String
    check tag, String
    @autorun ->
      query = accessibleMessagesQuery group, findUser @userId
      return @ready() unless query?
      query = $and: [
        query
        messagesTaggedQuery wildGroup, tag  ## no need to repeat group
      ]
      Messages.find addRootsToQuery query

@undeletedMessagesQuery = (group) ->
  query =
    group: group
    published: $ne: false
    deleted: $ne: true
  if group == wildGroup
    delete query.group
  query

@liveMessagesLimit = (limit) ->
  sort: [['updated', 'desc']]
  limit: parseInt limit

if Meteor.isServer
  Meteor.publish 'messages.live', (group, limit) ->
    check group, String
    limit = parseInt limit
    check limit, Number
    @autorun ->
      query = accessibleMessagesQuery group, findUser @userId
      return @ready() unless query?
      ## Mimicking Template.live.helpers' messages
      query = $and: [
        query
        undeletedMessagesQuery wildGroup  ## no need to repeat group
      ]
      options = liveMessagesLimit limit
      Messages.find addRootsToQuery query, options

@parseSince = (since) ->
  try
    match = /^\s*[+-]?\s*(\d+)\s*(\w+)\s*$/.exec since
    if match?
      moment().subtract(match[1], match[2]).toDate()
    else
      match = /^\s*(\d+)\s*:\s*(\d+)\s*$/.exec since
      if match?
        d = moment().hour(match[1]).minute(match[2])
        if moment().diff(d) < 0
          d = d.subtract(1, 'day')
        d.toDate()
      else
        d = moment(since)
        return null unless d.isValid()
        d.toDate()
  catch
    null

if Meteor.isServer
  Meteor.publish 'messages.since', (group, since) ->
    check group, String
    check since, String
    @autorun ->
      query = accessibleMessagesQuery group, findUser @userId
      return @ready() unless query?
      pSince = parseSince since
      return @ready() unless pSince?
      ## Mimicking since.coffee's messagesSince
      query.updated = $gte: pSince
      Messages.find addRootsToQuery query

if Meteor.isServer
  Meteor.publish 'messages.diff', (message) ->
    check message, String
    @autorun ->
      if canSee message, false, findUser @userId
        MessagesDiff.find
          id: message
      else
        @ready()

  Meteor.publish 'messages.neighbors', (root) ->
    check root, String
    if canSee root, false, findUser @userId
      init = true
      @autorun ->
        msg = Messages.findOne root
        return unless msg?
        messages = groupSortedBy msg.group, groupDefaultSort(msg.group),
          fields:
            title: 1
            group: 1
        , findUser @userId
        ids = (message._id for message in messages)
        index = ids.indexOf root
        neighbors = {}
        if index >= 0
          neighbors.prev = messages[index-1] if index > 0
          neighbors.next = messages[index+1] if index < messages.length - 1
        if init
          init = false
          @added 'messages.neighbors', root, neighbors
        else
          @changed 'messages.neighbors', root, neighbors
    @ready()

if Meteor.isClient
  @MessagesNeighbors = new Mongo.Collection 'messages.neighbors'

  @messageNeighbors = (root) ->
    return unless root
    unless _.isString root
      root = root._id
    MessagesNeighbors.findOne root

#if Meteor.isServer
#  Meteor.publish 'messages.summary', (group) ->
#    check group, String
#    roots = {}
#    @autorun =>
#      if groupRoleCheck group, 'read', findUser @userId
#        rootMessages(group).forEach (root) =>
#          summary =
#            count: _submessageCount root
#            updated: _submessageLastUpdate root
#          id = root._id
#          if id of roots
#            @changed 'messages.summary', id, summary
#          else
#            summary.root = id
#            @added 'messages.summary', id, summary
#            roots[id] = true
#    @ready()
#
#if Meteor.isClient
#  @MessagesSummary = new Mongo.Collection 'messages.summary'
#
#  @messageSummary = (root) ->
#    root = root._id if root._id?
#    MessagesSummary.findOne root

if Meteor.isServer
  ## Remove all editors on server start, so that we can restart listeners.
  Messages.find().forEach (message) ->
    if message.editing?.length
      Messages.update message._id,
        $unset: editing: ''

  onExit ->
    console.log 'EXITING'

@canSee = (message, client = Meteor.isClient, user = Meteor.user()) ->
  ## Visibility of a message is implied by its existence in the Meteor.publish
  ## above, so we don't need to check this in the client.  But this function
  ## is still needed in the server for messages.diff subscription above,
  ## and when simulating non-superuser mode in client/message.coffee.
  message = Messages.findOne message unless message._id?
  return false unless message?
  group = message.group #message2group message
  if canSuper group, client, user #groupRoleCheck group, 'super', user
    ## Super-user can see all messages, even unpublished/deleted messages.
    true
  else if groupRoleCheck group, 'read', user
    ## Regular users can see all messages they authored, plus
    ## published undeleted public messages by others.
    (message.published and not message.deleted and not message.private) or
    amAuthor message, user
  else
    false

@canPost = (group, parent) ->
  ## parent actually ignored
  Meteor.userId()? and
  groupRoleCheck group, 'post'

@canEdit = (message) ->
  ## Can edit message if an "author" (the creator or edited in the past),
  ## or if we have global edit privileges in this group.
  msg = Messages.findOne message
  return false unless msg?
  escapeUser(Meteor.user()?.username) of (msg.authors ? {}) or
  groupRoleCheck msg.group, 'edit'

@canDelete = canEdit
@canUndelete = canEdit
@canPublish = canEdit

@canUnpublish = (message) ->
  canSuper message2group message

@canSuper = (group, client = Meteor.isClient, user = Meteor.user()) ->
  ## If client is true, we use the session variable 'super' to fake whether
  ## superuser mode is viewed as on (from the client perspective).
  ## This lets someone with superuser permissions pretend to be normal.
  (not client or Session.get 'super') and
  groupRoleCheck group, 'super', user

@canImport = (group) -> canSuper group
@canSuperdelete = (message) ->
  canSuper message2group message

@amAuthor = (message, user = Meteor.user()) ->
  message = Messages.findOne message unless message._id?
  return false unless user?.username
  escapeUser(user.username) of (message.authors ? {}) or
  0 <= message.body.search ///@#{user.username}\b///

@canPrivate = (message) ->
  message = Messages.findOne message unless message._id?
  if canSuper message.group
    ## Superuser can always change private flag
    true
  else
    ## Regular user can change private flag for their own messages,
    ## and only if thread privacy allows for both public and private.
    unless amAuthor message
      false
    else
      root = findMessageRoot message
      root.threadPrivacy? and 'public' in root.threadPrivacy and 'private' in root.threadPrivacy

@canAdmin = (group) ->
  groupRoleCheck group, 'admin'

idle = 1000   ## one second

@message2group = (message) ->
  Messages.findOne(message)?.group

@findMessageParent = (message) ->
  message = message._id if message._id?
  parents = Messages.find
    children: message
  .fetch()
  switch parents.length
    when 0
      null
    when 1
      parents[0]
    else
      throw new Meteor.Error 'findMessageParent.multiple',
        "Message #{message} has #{parents.length} parents! #{parents}"

@findMessageRoot = (message) ->
  return message unless message?
  message = Messages.findOne message unless message._id?
  if message.root?
    Messages.findOne message.root
  else
    message

@messageEmpty = (message) ->
  message = Messages.findOne message unless message._id?
  message.title.trim().length == 0 and
  message.body.trim().length == 0 and
  not message.file

_noLongerRoot = (message) ->
  Messages.update message,
    $unset:
      submessageCount: ''
      submessageLastUpdate: ''

_submessagesChanged = (root) ->
  return unless root?
  Messages.update root,
    $set:
      submessageCount: _submessageCount root
      submessageLastUpdate: _submessageLastUpdate root

if Meteor.isServer
  rootMessages().forEach _submessagesChanged

checkPrivacy = (privacy, root) ->
  root = findMessageRoot root  ## can pass message or message ID
  switch privacy
    when true
      unless root?.threadPrivacy? and 'private' in root.threadPrivacy
        throw new Meteor.Error 'checkPrivacy.privateForbidden',
          "Cannot make message private in thread '#{root._id}'"
    when false
      unless root?.threadPrivacy? and 'public' in root.threadPrivacy
        throw new Meteor.Error 'checkPrivacy.publicForbidden',
          "Cannot reate message public in thread '#{root._id}'"
  null

## The following should be called directly only on the server;
## clients should use the corresponding method.
_messageUpdate = (id, message, authors = null, old = null) ->
  ## authors is set only when internal to server, in which case we bypass
  ## authorization checks, which already happened in messageEditStart.
  unless authors?
    check Meteor.userId(), String  ## should be done by 'canEdit'
    authors = [Meteor.user().username]
    return unless canEdit id
  check message,
    #url: Match.Optional String
    title: Match.Optional String
    body: Match.Optional String
    format: Match.Optional String
    file: Match.Optional String
    tags: Match.Optional Match.Where validTags
    #children: Match.Optional [String]  ## must be set via messageParent
    #parent: Match.Optional String      ## use children, not parent
    published: Match.Optional Boolean
    deleted: Match.Optional Boolean
    private: Match.Optional Boolean
  checkPrivacy message.private, id

  ## Don't update if there aren't any actual differences.  Compare with 'old'
  ## if provided (in cases when it's already been fetched by the server);
  ## otherwise, load id from Messages.
  old = Messages.findOne id unless old?
  diff = false
  for own key of message
    if old[key] != message[key]
      diff = true
      break
  return unless diff

  now = new Date
  if message.published == true
    message.published = now
  message.updated = now
  message.updators = authors
  for author in authors
    message["authors." + escapeUser author] = now
  Messages.update id,
    $set: message
  for author in authors
    delete message["authors." + escapeUser author]
  message.id = id
  diffid = MessagesDiff.insert message
  message._id = diffid
  _submessagesChanged old.root ? id
  notifyMessageUpdate message if Meteor.isServer  ## client in simulation
  diffid

_messageParent = (child, parent, position = null, oldParent = true, importing = false) ->
  ## oldParent is an internal option for server only; true means "search for/
  ## deal with old parent", while null means we assert there is no old parent.
  check Meteor.userId(), String  ## should be done by 'canEdit'
  check parent, String if parent != null
  check position, Number if position?
  #check oldParent, Boolean
  #check importing, Boolean
  if parent?
    pmsg = Messages.findOne parent
    unless pmsg
      console.warn 'Missing parent', parent, 'for child', child
      return  ## This should only happen in client simulation
    group = pmsg.group
    root = pmsg.root ? parent

    ## Check before creating a cycle in the parent pointers!
    ancestor = pmsg
    while ancestor?
      if ancestor._id == child
        throw new Meteor.Error 'messageParent.cycle',
          "Attempt to make #{child} its own ancestor (via #{parent})"
      ancestor = findMessageParent ancestor
  else
    group = child.group  ## xxx can't specify other group...
    root = null

  unless canEdit(child) and canPost group, parent
    throw new Meteor.Error 'messageParent.unauthorized',
      "Insufficient privileges to reparent message #{child} into #{parent}"

  cmsg = Messages.findOne child
  oldPosition = null
  oldSiblingsBefore = null
  oldSiblingsAfter = null
  if oldParent
    oldParentMsg = findMessageParent child
    if oldParentMsg?
      oldParent = oldParentMsg._id
      oldPosition = oldParentMsg.children.indexOf child
      return if parent == oldParent and (
        (position? and position == oldPosition) or
        (not position? and oldPosition == oldParentMsg.children.length-1)
      )  ## no-op
      oldSiblingsBefore = oldParentMsg.children[...oldPosition]
      oldSiblingsAfter = oldParentMsg.children[oldPosition+1..]
      Messages.update oldParent,
        $pull: children: child
    else
      oldParent = null
  return if parent == oldParent == null  ## no-op, root case
  if parent?
    if position?
      Messages.update parent,
        $push: children:
          $each: [child]
          $position: position
    else
      Messages.update parent,
        $push: children: child
  if root != cmsg.root
    Messages.update child,
      $set: root: root
    if cmsg.root?
      ## If we move a nonroot message to have new root, update descendants.
      descendants = descendantMessageIds child
      if descendants.length > 0
        Messages.update
          _id: $in: descendants
        ,
          $set: root: root ? child
        ,
          multi: true
    else
      ## To reparent root message, change the root of all descendants.
      Messages.update
        root: child
      ,
        $set: root: root ? child  ## actually must be root
      ,
        multi: true
      _noLongerRoot child if root?
    _submessagesChanged cmsg.root     ## old root
    _submessagesChanged root ? child  ## new root

  doc =
    child: child
    parent: parent
    position: position
    oldParent: oldParent
    oldPosition: oldPosition
    oldSiblingsBefore: oldSiblingsBefore
    oldSiblingsAfter: oldSiblingsAfter
  if importing
    #cmsg = Messages.findOne child
    doc.updator = cmsg.creator
    doc.updated = cmsg.created
  else
    doc.updator = Meteor.user().username
    doc.updated = new Date
  MessagesParent.insert doc

if Meteor.isServer
  editorTimers = {}

  `import {ShareJS} from 'meteor/mizzao:sharejs'`

  ## If we're using a persistent store for sharejs, we need to cleanup
  ## leftover documents from last time.  This should only be for local
  ## testing, but deleting them at startup prevents more catastrophic
  ## failure when creating a duplicate ID.
  docs = new Mongo.Collection 'docs'
  docs.find().forEach (doc) ->
    ShareJS.model.delete doc._id

  editor2messageUpdate = (id) ->
    Meteor.clearTimeout editorTimers[id]
    doc = Meteor.wrapAsync(ShareJS.model.getSnapshot) id
    #console.log id, 'changed to', doc.snapshot
    msg = Messages.findOne id
    unless msg.body == doc.snapshot
      _messageUpdate id,
        body: doc.snapshot
      , msg.editing, msg

  delayedEditor2messageUpdate = (id) ->
    Meteor.clearTimeout editorTimers[id]
    editorTimers[id] = Meteor.setTimeout ->
      editor2messageUpdate id
    , idle

Meteor.methods
  messageUpdate: (id, message) -> _messageUpdate id, message

  messageNew: (group, parent = null, position = null, message = {}) ->
    #check Meteor.userId(), String  ## should be done by 'canPost'
    check parent, String if parent?
    check position, Number if position?
    check group, String
    check message,
      title: Match.Optional String
      body: Match.Optional String
      format: Match.Optional String
      file: Match.Optional String
      tags: Match.Optional Match.Where validTags
      #children: Match.Optional [String]  ## must be set via messageParent
      #parent: Match.Optional String      ## use children, not parent
      published: Match.Optional Boolean
      deleted: Match.Optional Boolean
      private: Match.Optional Boolean
    unless canPost group, parent
      throw new Meteor.Error 'messageNew.unauthorized',
        "Insufficient permissions to post new message in group '#{group}' under parent '#{parent}'"
    root = findMessageRoot parent
    checkPrivacy message.private, root
    unless message.private?
      ## Default to match parent
      if parent?
        pmsg = Messages.findOne parent
        message.private = pmsg.private if pmsg.private?
      ## Old default: public if available, private otherwise
      #if root.threadPrivacy? and 'public' not in root.threadPrivacy
      #  message.private = true
    now = new Date
    username = Meteor.user().username
    message.creator = username
    message.created = now
    message.authors =
      "#{escapeUser username}": now
    message.group = group
    #message.parent: parent         ## use children, not parent
    message.children = []
    ## Default content.
    message.title = "" unless message.title?
    message.body = "" unless message.body?
    message.format = Meteor.user()?.profile?.format or defaultFormat unless message.format?
    message.tags = {} unless message.tags?
    message.published = autopublish() unless message.published?
    message.updators = [Meteor.user().username]
    message.updated = now
    if message.published == true
      message.published = now
    message.deleted = false unless message.deleted?
    ## Now handled by _messageParent
    #if parent?
    #  pmsg = Messages.findOne parent
    #  message.root = pmsg.root ? parent
    id = Messages.insert message
    ## Prepare for MessagesDiff
    delete message.creator
    delete message.created
    delete message.authors
    delete message.children
    delete message.root
    message.id = id
    diffid = MessagesDiff.insert message
    message._id = diffid
    if parent?
      _messageParent id, parent, position, null  ## there's no old parent
    else
      _submessagesChanged message
    notifyMessageUpdate message, true if Meteor.isServer  ## created = true
    id

    ## Initial URL (short name) is the Mongo-provided ID.  User can edit later.
    #message.url = id
    #Messages.update id,
    #  $set:
    #    url: id
    #message

  messageParent: (child, parent, position = null) ->
    ## Notably, disabling oldParent search and importing options are not
    ## allowed from client, only internal to server.
    _messageParent child, parent, position

  messageEditStart: (id) ->
    #check Meteor.userId(), String  ## should be done by 'canEdit'
    unless canEdit id
      throw new Meteor.Error 'messageEditStart.unauthorized',
        "Insufficient permissions to edit message '#{id}'"
    if Meteor.isServer
      old = Messages.findOne id
      return unless old?
      unless old.editing?.length
        ShareJS.model.delete id
        ShareJS.initializeDoc id, old.body ? ''
        timer = null
        listener = Meteor.bindEnvironment (opData) ->
          delayedEditor2messageUpdate id
        ShareJS.model.listen id, listener
      ## We used to do the following update in client too, to do
      ## speculatively, but it seems problematic for now.
      Messages.update id,
        $addToSet: editing: Meteor.user().username

  messageEditStop: (id) ->
    check Meteor.userId(), String
    if Meteor.isServer
      ## We used to do the following update in client too, to do
      ## speculatively, but it seems problematic for now.
      Messages.update id,
        $pull: editing: Meteor.user().username
      unless Messages.findOne(id).editing?.length
        editor2messageUpdate id
        ShareJS.model.delete id
    ## xxx should add to last MessagesDiff (possibly just made) that
    ## Meteor.user().username just committed this version.

  messageImport: (group, parent, message, diffs) ->
    #check Meteor.userId(), String  ## should be done by 'canImport'
    check group, String
    check parent, String if parent?
    check message,
      title: Match.Optional String
      body: Match.Optional String
      format: Match.Optional String
      file: Match.Optional String
      tags: Match.Optional Match.Where validTags
      #children: Match.Optional [String]  ## must be set via messageParent
      #parent: Match.Optional String      ## use children, not parent
      published: Match.Optional Match.OneOf Date, Boolean
      deleted: Match.Optional Boolean
      #private: Match.Optional Boolean
      creator: Match.Optional String
      created: Match.Optional Date
      #updated and updators added automatically from last diff
    check diffs, [
      title: Match.Optional String
      body: Match.Optional String
      format: Match.Optional String
      file: Match.Optional String
      tags: Match.Optional Match.Where validTags
      deleted: Match.Optional Boolean
      #private: Match.Optional Boolean
      updated: Match.Optional Date
      updators: Match.Optional [String]
      published: Match.Optional Match.OneOf Date, Boolean
    ]
    unless canImport group
      throw new Meteor.Error 'messageImport.unauthorized',
        "Insufficient permissions to import into group '#{group}'"
    now = new Date
    me = Meteor.user().username
    if message.published == true
      message.published = now
    message.deleted = false unless message.deleted?
    diffs[0].deleted = false unless diffs[0].deleted?
    message.group = group
    message.children = []
    message.updated = diffs[diffs.length-1].updated
    message.updators = diffs[diffs.length-1].updaors
    message.importer = me
    message.imported = now
    ## Automatically set 'authors' to have the latest update for each author.
    message.authors = {}
    for diff in diffs
      for author in diff.updators
        message.authors[author] = diff.updated
    #if parent?
    #  pmsg = Messages.findOne parent
    #  message.root = pmsg.root ? parent
    id = Messages.insert message
    for diff in diffs
      diff.id = id
      diff.group = group
      diff.importer = me
      diff.imported = now
      MessagesDiff.insert diff
    if parent?
      _messageParent id, parent, null, null, true
    else
      _submessagesChanged message
    id

  messageSuperdelete: (message) ->
    #check Meteor.userId(), String  ## should be done by 'canSuperdelete'
    check message, String
    unless canSuperdelete message
      throw new Meteor.Error 'messageSuperdelete.unauthorized',
        "Insufficient permissions to superdelete in group '#{group}'"
    user = Meteor.user().username
    now = new Date
    msg = Messages.findOne message
    return unless msg?
    Messages.remove message
    children = msg.children
    parent = findMessageParent message
    if parent?
      Messages.update parent._id,
        $pull: children: message
      Messages.update parent._id,
        $push: children:
          $each: children
          $position: parent.children.indexOf message
      ## children roots remain the same in this case
      _submessagesChanged msg.root
      for child, i in children
        MessagesParent.insert
          child: child
          position: i + parent.children.indexOf message
          parent: parent
          updator: user
          updated: now
    else
      #_submessagesChanged message  ## unnecessary now that it's deleted
      for child in children
        Messages.update child,
          $unset: root: ''
        _submessagesChanged child
    
    ## Delete all associated files.
    MessagesDiff.find
      id: message
    .forEach (diff) ->
      if diff.file
        deleteFile diff.file
    ## Delete all diffs for this message.
    MessagesDiff.remove
      id: message
    ## Delete all parent references to this message.
    MessagesParent.remove
      $or: [
        child: message
      , parent: message
      ]

  threadPrivacy: (message, list) ->
    #check Meteor.userId(), String  ## should be done by 'canSuper'
    check message, String
    check list, [Match.OneOf 'public', 'private']
    list = _.uniq list  ## remove any duplicates
    unless canSuper message2group message
      throw new Meteor.Error 'threadPrivacy.unauthorized',
        "Insufficient permissions to change privacy for thread '#{message}'"
    msg = Messages.findOne message
    if msg.root?
      throw new Meteor.Error 'threadPrivacy.nonroot',
        "Can change thread privacy only for root messages, not '#{message}'"
    Messages.update message,
      $set: threadPrivacy: list

  recomputeAuthors: ->
    ## Force recomputation of all `authors` fields to be the latest update
    ## for each updator.
    #check Meteor.userId(), String  ## should be done by 'canSuper'
    unless canSuper wildGroup
      throw new Meteor.Error 'recomputeAuthors.unauthorized',
        "Insufficient permissions to recompute authors in group '#{wildGroup}'"
    Messages.find({}).forEach (msg) ->
      authors = {}
      updated = updators = null
      MessagesDiff.find
        id: msg._id
      .forEach (diff) ->
        updated = diff.updated
        updators = diff.updators
        for updator in updators
          escape = escapeUser updator
          if escape not of authors or authors[escape].getTime() < updated.getTime()
            authors[escape] = updated
      Messages.update msg._id,
        $set:
          authors: authors
          updated: updated    ## last one
          updators: updators  ## last one

  recomputeRoots: ->
    #check Meteor.userId(), String  ## should be done by 'canSuper'
    unless canSuper wildGroup
      throw new Meteor.Error 'recomputeRoots.unauthorized',
        "Insufficient permissions to recompute roots in group '#{wildGroup}'"
    rootMessages().forEach (root) ->
      descendants = descendantMessageIds root
      if descendants.length > 0
        Messages.update
          _id: $in: descendants
        ,
          $set: root: root._id
        ,
          multi: true

## Upgrade from old file message format (format 'file', body = file pointer)
## to new file message format (file = file pointer)
if Meteor.isServer
  Messages.find
    format: 'file'
  .forEach (msg) ->
    Messages.update msg._id,
      $set:
        format: defaultFormat
        title: ''
        body: ''
        file: msg.body
  MessagesDiff.find
    format: 'file'
  .forEach (diff) ->
    MessagesDiff.update diff._id,
      $set:
        format: defaultFormat
        title: ''
        body: ''
        file: diff.body
