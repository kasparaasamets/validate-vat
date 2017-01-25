url = require 'url'
http = require 'http'

serviceUrl = 'http://ec.europa.eu/taxation_customs/vies/services/checkVatService'

parsedUrl = url.parse serviceUrl

soapBodyTemplate = '''
<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"
  xmlns:tns1="urn:ec.europa.eu:taxud:vies:services:checkVat:types"
  xmlns:impl="urn:ec.europa.eu:taxud:vies:services:checkVat">
  <soap:Header>
  </soap:Header>
  <soap:Body>
    <tns1:checkVatApprox xmlns:tns1="urn:ec.europa.eu:taxud:vies:services:checkVat:types"
     xmlns="urn:ec.europa.eu:taxud:vies:services:checkVat:types">
     <tns1:countryCode>_country_code_placeholder_</tns1:countryCode>
     <tns1:vatNumber>_vat_number_placeholder_</tns1:vatNumber>
    _requester_placeholder_
    </tns1:checkVatApprox>
  </soap:Body>
</soap:Envelope>
'''

EU_COUNTRIES_CODES = ['AT', 'BE', 'BG', 'HR', 'CY', 'CZ', 'DK', 'EE', 'FI', 'FR', 'DE', 'EL', 'HU',
                      'IE', 'IT', 'LV', 'LT', 'LU', 'MT', 'NL', 'PL', 'PT', 'RO', 'SK', 'SI', 'ES', 'SE', 'GB']

SERVICE_ERRORS = ['SERVICE_UNAVAILABLE', 'MS_UNAVAILABLE', 'TIMEOUT', 'SERVER_BUSY', 'UNKNOWN']

ERROR_MSG =
  'INVALID_INPUT': 'The provided CountryCode is invalid or the VAT number is empty'
  'SERVICE_UNAVAILABLE': 'The VIES VAT service is unavailable, please try again later'
  'MS_UNAVAILABLE': 'The VAT database of the requested member country is unavailable, please try again later'
  'TIMEOUT': 'The request to VAT database of the requested member country has timed out, please try again later'
  'SERVER_BUSY': 'The service cannot process your request, please try again later'
  'UNKNOWN': 'Unknown error'

headers =
  'Content-Type': 'application/x-www-form-urlencoded'
  'User-Agent': 'node-soap'
  'Accept' : 'text/html,application/xhtml+xml,application/xml,text/xml;q=0.9,*/*;q=0.8'
  'Accept-Encoding': 'none'
  'Accept-Charset': 'utf-8'
  'Connection': 'close'
  'Host' : parsedUrl.hostname
  'SOAPAction': 'urn:ec.europa.eu:taxud:vies:services:checkVat/checkVat'

getReadableErrorMsg = (faultstring) ->
  if ERROR_MSG[faultstring]?
    return ERROR_MSG[faultstring]
  else
    return ERROR_MSG['UNKNOWN']

# I don't really want to install any xml parser which may require multpiple packages
parseSoapResponse = (soapMessage) ->
  parseField = (field) ->
    regex = new RegExp "<#{field}>\((\.|\\s)\*\)</#{field}>", 'gm'
    match = regex.exec(soapMessage)
    if !match
      err = new Error "Failed to parseField #{field}"
      err.soapMessage = soapMessage
      throw err
    return match[1]

  hasFault = soapMessage.match /<soap:Fault>\S+<\/soap:Fault>/g
  if hasFault
    ret =
      faultCode: parseField 'faultcode'
      faultString: parseField 'faultstring'
  else
    ret =
      countryCode: parseField 'countryCode'
      vatNumber: parseField 'vatNumber'
      requestDate: parseField 'requestDate'
      valid: parseField('valid') is 'true'
      name: parseField 'traderName'
      address: parseField('traderAddress').replace /\n/g, ', '
      reqId: parseField('requestIdentifier')

  return ret

module.exports = exports = (params, callback) ->
  if params.countryCode not in EU_COUNTRIES_CODES or !params.vatNumber?.length
    return process.nextTick -> callback new Error ERROR_MSG['INVALID_INPUT']

  xml = soapBodyTemplate.replace('_country_code_placeholder_', params.countryCode)
  .replace('_vat_number_placeholder_', params.vatNumber)
  .replace('\n', '').trim()

  if params.requesterCountryCode or params.requesterVatNumber
    requesterXml = '<tns1:requesterCountryCode>' + params.requesterCountryCode + '</tns1:requesterCountryCode>' +
      '<tns1:requesterVatNumber>' + params.requesterVatNumber + '</tns1:requesterVatNumber>'
    xml = xml.replace('_requester_placeholder_', requesterXml)
  else
    xml = xml.replace('_requester_placeholder_', '')

  headers['Content-Length'] = Buffer.byteLength xml, 'utf8'

  options =
    host: parsedUrl.host
    method: 'POST',
    path: parsedUrl.path
    headers: headers

  req = http.request options, (res) ->
    res.setEncoding 'utf8'
    str = ''
    res.on 'data', (chunk) ->
      str += chunk

    res.on 'end', ->
      try
        data = parseSoapResponse str
      catch err
        return callback err

      if data.faultString?.length
        err = new Error getReadableErrorMsg data.faultString
        if SERVICE_ERRORS.indexOf(data.faultString)
          err.isVatServiceError = true
        err.code = data.faultCode
        return callback err

      return callback null, data

  if params.timeout
    req.setTimeout params.timeout, ->
      err = new Error(getReadableErrorMsg('TIMEOUT'))
      err.isVatServiceError = true
      callback err

  req.on 'error', callback
  req.write xml
  req.end()

