###
Adapted from the "LogsToElasticsearch" Node 4.3 code produced by the Console during manual configurations.  This accepts compressed CloudWatch log data from a subscriber, parses it, and uploads N JSON documents to the Elasticsearch domain in question.
###
import https from "https"
import URL from "url"
import zlib from "zilb"
import crypto from "crypto"

#var endpoint = 'search-dashkite-david-logs-zpbwhl7k443m74mqubalmxtx2u.us-east-1.es.amazonaws.com';

merge = (objects...) -> Object.assign {}, objects...

unzip = (input) ->
  new Promise (resolve, reject) ->
    zlib.gunzip input, (error, buffer) ->
      if error
        reject error
      else
        resolve buffer

parseReport = (message) ->
  requestId: RegExp("^REPORT RequestId\: (.*?)\t").exec(message)[1]
  duration: RegExp("\tDuration: (.*?) ms\t").exec(message)[1]
  memory: RegExp("\tMax Memory Used: (.*?) MB\t").exec(message)[1]

parseRegular = (record, message) ->
  requestId: RegExp("^(.*?)\t(.*?)\t").exec(message)[2]

buildDoc = (handler, {id, timestamp, message}) ->
  doc = {id, handler, timestamp, message}
  if RegExp("^REPORT").test message
    merge doc, (parseReport message)
  else
    merge doc, parseRegular message

transform = (payload) ->
  bulkRequestBody = ""
  handler = payload.logGroup.slice 12

  payload.logEvents.forEach (logEvent) ->
    doc = buildDocument handler, logEvent
    action =
      index:
        _index: process.env.indexName
        _type: process.env.indexType
        _id: logEvent.id

    bulkRequestBody += [
      JSON.stringify(action)
      JSON.stringify(doc).replace(/\\n/g, "")
    ].join('\n') + "\n"

  bulkRequestBody

buildRequest = (body) ->
  options = URL.parse process.env.endpoint
  headers =
    "Content-Type": "application/json"
    "Host": options.host
    "Content-Length": Buffer.byteLength body

  merge options, {method: "POST", path:"_bulk", body, headers}

post = (body) ->
  responseBody = ""
  requestParams = buildRequest body

  new Promise (resolve, reject) ->
    request = https.request requestParams, (response) ->
      response.on 'data', (chunk) -> responseBody += chunk
      response.on 'end', ->
        info = JSON.parse responseBody
        if response.statusCode >= 200 && response.statusCode < 299
          failedItems = info.items.filter (x) -> x.index.status >= 300

        success =
          attemptedItems: info.items.length
          successfulItems: info.items.length - failedItems.length
          failedItems: failedItems.length

        error =
          if response.statusCode != 200 || info.errors == true
            statusCode: response.statusCode
            responseBody: responseBody
          else
            null

        resolve {error, success, statusCode: response.statusCode, failedItems}
    .on 'error', (e) -> reject e

    request.end requestParams.body

parseResponse = (callback, {error, success, statusCode, failedItems}) ->
  console.log "Response: #{JSON.stringify {statusCode}}"
  if error
    console.log "Error: #{JSON.stringify error, null, 2}"
    if failedItems?.length > 0
      console.log "Failed Items: #{JSON.stringify failedItems, null, 2}"
    callback JSON.stringify error
  else
    console.log "Success: #{JSON.stringify success}"
    callback null, "Success"


handler = (input, context, callback) ->
  try
    # decode input from base64
    zippedInput = Buffer.from input.awslogs.data, "base64"

    # decompress the input
    buffer = await unzip zippedInput

    # parse the input from JSON
    awslogsData = JSON.parse buffer.toString()

    # skip control messages
    if awsLogsData.messageType == 'CONTROL_MESSAGE'
        console.log "Received a control message."
        callback null, "Control messaged handled successfully"
        return

    # transform the input to Elasticsearch documents
    esBulkBody = transform awslogsData

    # post documents to the Amazon Elasticsearch Service
    response = await post esBulkBody

    parseResponse callback, response

  catch e
    console.log "Log transform failure", e.stack
    callback e.message

export {handler}