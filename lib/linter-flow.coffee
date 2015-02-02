{BufferedProcess} = require 'atom'
linterPath = atom.packages.getLoadedPackage('linter').path
Linter = require "#{linterPath}/lib/linter"
findFile = require "#{linterPath}/lib/util"

path = require "path"
fs = require 'fs'
{spawn} = require 'child_process'

_ = require 'underscore-plus'

log = (args...) ->
  if atom.config.get 'linter.lintDebug'
    console.log args...

warn = (args...) ->
  if atom.config.get 'linter.lintDebug'
    console.warn args...

class LinterFlow extends Linter
  # The syntax that the linter handles. May be a string or
  # list/tuple of strings. Names should be all lowercase.
  @syntax: ['source.js']

  cmd: ['flow', 'status', '--json']

  executablePath: undefined

  # A list of all the flow server instances started by this linter.
  flowServers: []

  linterName: 'flow'

  serverStartMessage: /^Flow server launched for (.+)$/

  lintFile: (filePath, callback) ->
    unless @executablePath?
      callback []
      return

    # Can't use the temp files because it breaks relative imports.
    # https://github.com/AtomLinter/Linter/issues/282
    realPath = @editor.getPath()
    # build the command with arguments to lint the file
    {command, args} = @getCmdAndArgs(realPath)

    # options for BufferedProcess, same syntax with child_process.spawn
    options = {cwd: @cwd}

    dataStdout = []
    dataStderr = []
    exited = false

    stdout = (output) ->
      log 'stdout', output
      dataStdout += output

    stderr = (output) ->
      warn 'stderr', output
      dataStderr += output

    exit = =>
      exited = true
      # Keep track of any servers that were launched.
      if dataStderr.length
        _.forEach dataStderr.split('\n'), (msg) =>
          msg.replace @serverStartMessage, (m, path) =>
            console.log "Flow server launched for #{path}"
            console.log 'Initial linter results may take some time. Please wait...'
            @flowServers = _.union @flowServers, [path]
      try
        # The JSON payload will be the last line of text.
        info = JSON.parse dataStdout
      catch
        warn dataStdout
        callback []
        return

      if info.passed
        callback []
        return

      realMessages = []
      _.each info.errors, (msg) ->

        # NB: messages are often of the form "X is bad", "because", "some other type"
        # Therefore, we want to categorize the first message as the actual error, and
        # subsequent errors as warnings (so people can find the related type quickly),
        # but also have a good error message in the real message
        first = true
        _.each msg.message, (item) ->
          if first
            toPush = _.extend item,
              error: true
              warning: false
              descr: _.map(msg.message, (x) -> x.descr.replace("\n", " ")).join(' ')

            last = _.last(msg.message)
            unless msg.message.length < 2
              toPush.descr += "(#{last.path.replace(atom.project.path, '.')}:#{last.line})"

            log "Message: #{toPush.message}"
            realMessages.push(toPush)
            first = false
            return

          realMessages.push(_.extend(item, error: false, warning: true))
          first = false

      # NB: Sometimes, the type definition for the 'some other type' can be in
      # a separate file
      realMessages = _.filter realMessages, (x) ->
        return true if x.path is null
        return (path.basename(x.path) is path.basename(filePath))

      ## NB: This parsing code pretty much sucks, but at least does what
      ## we want it to for now
      messages = _.map realMessages, (x) ->
        _.extend {},
          message: x.descr.replace("\n", " ")
          line: x.line
          lineStart: x.line
          lineEnd: x.endline
          colStart: x.start
          colEnd: x.end
          warning: x.warning
          error: x.error

      log(messages)

      callback(_.map(messages, (x) => @createMessage(x)))
      return


    process = new BufferedProcess({command, args, options,
                                  stdout, stderr, exit})

    # Kill the linter process if it takes too long
    if @executionTimeout > 0
      setTimeout =>
        return if exited
        process.kill()
        warn "command `#{command}` timed out after #{@executionTimeout} ms"
      , @executionTimeout

  processMessage: (message, callback) ->

  findFlowInPath: ->
    pathItems = process.env.PATH.split /[;:]/

    _.find pathItems, (x) ->
      return false unless x and x.length > 1
      fs.existsSync(path.join(x, 'flow'))

  constructor: (editor) ->
    super(editor)

    @executablePath = @findFlowInPath()

    unless @executablePath?
      console.log 'Flow is disabled. Make sure the flow executable is in your $PATH.'

  destroy: ->
    _.forEach @flowServers, (projectPath) =>
      console.log "shutting down flow server for #{projectPath}"
      spawn @executablePath, ['flow', 'stop', projectPath]

module.exports = LinterFlow
