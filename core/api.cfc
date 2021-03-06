<cfcomponent hint="Base class for taffy REST application's Application.cfc">

	<cfscript>
		//you can override these methods in your application.cfc
		function applicationStartEvent(){}	//override this function to run your own code inside onApplicationStart()
		function requestStartEvent(){}		//override this function to run your own code inside onRequestStart()
		function configureTaffy(){}			//override this function to set Taffy config settings
		
		/** onTaffyRequest gives you the opportunity to inspect the request before it is marshalled to the service.
		  * If you override this function, you MUST either return TRUE or a response object (same class as services).
		  */
		function onTaffyRequest(string verb, string cfc, struct requestArguments, string mimeExt){return true;}

		/* DO NOT OVERRIDE THIS FUNCTION - SEE applicationStartEvent ABOVE */
		function onApplicationStart(){
			applicationStartEvent();
			setupFramework();
			return true;
		}
		/* DO NOT OVERRIDE THIS FUNCTION - SEE requestStartEvent ABOVE */
		function onRequestStart(){
			if (structKeyExists(url, application._taffy.settings.reloadKey) and url[application._taffy.settings.reloadKey] eq application._taffy.settings.reloadPassword){
				setupFramework();
			}
			requestStartEvent();
			return true;
		}
    </cfscript>


	<!--- :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: --->
	<!--- :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: --->

	<!--- short-circuit logic --->
	<cffunction name="onRequest" output="true" returntype="boolean">
		<cfargument name="targetPage" type="string" required="true" />

		<cfset var _taffyRequest = {} />

		<cfif not structKeyExists(url, application._taffy.settings.debugKey)>
			<cfsetting showdebugoutput="false" />
		</cfif>

		<!--- api dashboard --->
		<cfif structKeyExists(url, "dashboard")>
			<cfinclude template="dashboard.cfm" />
			<cfabort>
		</cfif>
		
		<!--- get request details --->
		<cfset _taffyRequest = parseRequest() />

		<!---
			Now we know everything we need to know to service the request. let's service it!
		--->
		
		<!--- ...after we let the api developer know all of the request details first... --->
		<cfset _taffyRequest.continue = onTaffyRequest(
			_taffyRequest.verb,
			_taffyRequest.matchDetails.cfc,
			_taffyRequest.requestArguments,
			_taffyRequest.returnMimeExt
		) />
		
		<cfif not structKeyExists(_taffyRequest, "continue")>
			<!--- developer forgot to return true --->
			<cfthrow 
				message="Error in your onTaffyRequest method" 
				detail="Your onTaffyRequest method returned no value. Expected: TRUE or a Response Object." 
				errorcode="400"
			/>
		</cfif>
		
		<cfif isObject(_taffyRequest.continue)>
			<!--- inspection complete but request has been aborted by developer; return custom response --->
			<cfset _taffyRequest.result = _taffyRequest.continue />
			<cfset structDelete(_taffyRequest, "continue")/>
		<cfelse>
			<!--- inspection complete and request allowed by developer; marshall request to service --->

			<!--- make sure the cfc is cached, if not, load it and get some meta-data about it --->
			<cfif not structKeyExists(application._taffy.endpointCache, _taffyRequest.matchDetails.cfc)>
				<cfset cacheEndpoint(_taffyRequest.matchDetails.cfc) />
			</cfif>
			<!--- if the verb is not implemented, refuse the request --->
			<cfif not structKeyExists(application._taffy.endpointCache[_taffyRequest.matchDetails.cfc].methods, _taffyRequest.verb)>
				<cfset throwError(405, "Method Not Allowed") />
			</cfif>
			<!--- returns a representation-object --->
			<cfinvoke
				component="#application._taffy.endpointCache[_taffyRequest.matchDetails.cfc].cfc#"
				method="#_taffyRequest.verb#"
				argumentcollection="#_taffyRequest.requestArguments#"
				returnvariable="_taffyRequest.result"
			/>
		</cfif>

		<!--- serialize the representation into the requested mime type --->
		<cfinvoke
			component="#_taffyRequest.result#"
			method="getAs#_taffyRequest.returnMimeExt#"
			returnvariable="_taffyRequest.resultSerialized"
		/>
		<!--- get status code --->
		<cfinvoke
			component="#_taffyRequest.result#"
			method="getStatus"
			returnvariable="_taffyRequest.resultStatus"
		/>

		<cfsetting enablecfoutputonly="true" />
		<cfcontent reset="true" type="#application._taffy.settings.mimeExtensions[_taffyRequest.returnMimeExt]#" />
		<cfheader statuscode="#_taffyRequest.resultStatus#"/>
		<cfif _taffyRequest.resultSerialized neq """""">
			<cfoutput>#_taffyRequest.resultSerialized#</cfoutput>
		</cfif>

		<cfif structKeyExists(url, application._taffy.settings.debugKey)>
			<cfoutput><h3>Request Details:</h3><cfdump var="#_taffyRequest#"></cfoutput>
		</cfif>

		<cfreturn true />
	</cffunction>

	<!--- :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: --->
	<!--- :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: --->

	<!--- internal methods --->
	<cffunction name="setupFramework" access="private" output="false" returntype="void">
		<cfset application._taffy = structNew()/>
		<cfset application._taffy.endpoints = {} />
		<cfset application._taffy.endpointCache = {} />
		<cfset application._taffy.settings = {
			defaultMime = "json",
			debugKey = "debug",
			reloadKey = "reload",
			reloadPassword = "true",
			defaultRepresentationClass = "taffy.core.genericRepresentation"
		} />
		<cfset registerMimeType("json", "application/json") />
		<cfset configureTaffy()/>
	</cffunction>
	<cffunction name="parseRequest" access="private" output="false" returnType="struct">
		<cfset var requestObj = {} />
		<cfset var tmp = 0 />
		
		<!--- attempt to find the cfc for the requested uri --->
		<cfset requestObj.matchingRegex = matchURI(cgi.path_info) />

		<!--- uri doesn't map to any known resources --->
		<cfif not len(requestObj.matchingRegex)>
			<cfset throwError(404, "Not Found") />
		</cfif>

		<!--- get the cfc name and token array for the matching regex --->
		<cfset requestObj.matchDetails = application._taffy.endpoints[requestObj.matchingRegex] />

		<!--- which verb is requested? --->
		<cfset requestObj.verb = cgi.request_method />
		
		<cfif ucase(requestObj.verb) eq "PUT">
			<cfset requestObj.queryString = getPutParameters() />
		<cfelse>
			<cfset requestObj.queryString = cgi.query_string />
		</cfif>

		<!--- build the argumentCollection to pass to the cfc --->
		<cfset requestObj.requestArguments = buildRequestArguments(
			requestObj.matchingRegex,
			requestObj.matchDetails.tokens,
			cgi.path_info,
			requestObj.queryString
		) />
		<!--- also capture form POST data (higher priority that url variables of same name) --->
		<cfset structAppend(requestObj.requestArguments, form) />

		<!--- use requested mime type or the default --->
		<cfset requestObj.returnMimeExt = "" />
		<cfif structKeyExists(requestObj.requestArguments, "_taffy_mime")>
			<cfset requestObj.returnMimeExt = requestObj.requestArguments["_taffy_mime"] />
			<cfset structDelete(requestObj.requestArguments, "_taffy_mime") />
		<cfelse>
			<cfif structKeyExists(cgi, "http_accept") and len(cgi.http_accept)>
				<cfloop list="#cgi.HTTP_ACCEPT#" index="tmp">
					<!--- deal with that q=0 stuff (just ignore it) --->
					<cfif listLen(tmp, ";") gt 1>
						<cfset tmp = listFirst(tmp, ";") />
					</cfif>
					<cfif structKeyExists(application._taffy.settings.mimeTypes, tmp)>
						<cfset requestObj.returnMimeExt = application._taffy.settings.mimeTypes[tmp] />
					<cfelse>
						<cfset requestObj.returnMimeExt = application._taffy.settings.defaultMime />
					</cfif>
				</cfloop>
			</cfif>
		</cfif>
		<cfreturn requestObj />
	</cffunction>
	<cffunction name="convertURItoRegex" access="private" output="false">
		<cfargument name="uri" type="string" required="true" hint="wants the uri mapping defined by the cfc endpoint" />

		<cfset var almostTokens = rematch("{([^}]+)}", arguments.uri)/>
		<cfset var token = '' />
		<cfset var returnData = { tokens = [] } />

		<!--- extract token names and values from requested uri --->
		<cfset var uriRegex = arguments.uri />
		<cfloop array="#almostTokens#" index="token">
			<cfset arrayAppend(returnData.tokens, replaceList(token, "{,}", ",")) />
			<cfset uriRegex = rereplaceNoCase(uriRegex,"{[^}]+}", "([^\/\.]+)") />
		</cfloop>

		<!--- require the uri to terminate after specified content --->
		<cfset uriRegex &=
						"(\.[^\.\?]+)?"		<!--- anything other than these characters will be considered a mime-type request: / \ ? . --->
						& "$" />			<!--- terminate the uri (query string not included in cgi.path_info, does not need to be accounted for here) --->

		<cfset returnData.uriRegex = uriRegex />

		<cfreturn returnData />
	</cffunction>
	<cffunction name="matchURI" access="private" output="false" returnType="string">
		<cfargument name="requestedURI" type="string" required="true" hint="probably just pass in cgi.path_info" />
		<cfset var endpoint = '' />
		<cfloop collection="#application._taffy.endpoints#" item="endpoint">
			<cfset attempt = reMatchNoCase(endpoint, arguments.requestedURI) />
			<cfif arrayLen(attempt) gt 0>
				<!--- found our mapping --->
				<cfreturn endpoint />
			</cfif>
		</cfloop>
		<!--- nothing found --->
		<cfreturn "" />
	</cffunction>
	<cffunction name="getPutParameters" access="private" output="false" returntype="String" hint="Gets PUT data into a string similar to cgi.query_string, which CF doesn't do automatically">
		<!--- Special thanks to Jason Dean (@JasonPDean) and Ray Camden (@ColdFusionJedi) who helped me figure out how to do this --->
		<cfreturn getHTTPRequestData().content />
	</cffunction>
	<cffunction name="buildRequestArguments" access="private" output="false" returnType="struct">
		<cfargument name="regex" type="string" required="true" hint="regex that describes the request (including uri and query string parameters)" />
		<cfargument name="tokenNamesArray" type="array" required="true" hint="array of token names associated with the matched uri" />
		<cfargument name="uri" type="string" required="true" hint="the requested uri" />
		<cfargument name="queryString" type="string" required="true" hint="any query string parameters included in the request" />
		<cfset var returnData = {} /><!--- this will be used as an argumentCollection for the method that ultimately gets called --->
		<cfset var t = '' />
		<cfset var i = '' />
		<!--- parse path_info data into key-value pairs --->
		<cfset var tokenValues = reFindNoSuck(arguments.regex, arguments.uri) />
		<cfset var numTokenValues = arrayLen(tokenValues) />
		<cfset var numTokenNames = arrayLen(arguments.tokenNamesArray) />
		<cfif numTokenNames gt 0>
			<cfloop from="1" to="#numTokenNames#" index="t">
				<cfset returnData[arguments.tokenNamesArray[t]] = tokenValues[t] />
			</cfloop>
		</cfif>
		<!--- also parse query string parameters into key-value pairs --->
		<cfloop list="#arguments.queryString#" delimiters="&" index="t">
			<cfset returnData[listFirst(t,'=')] = urlDecode(listLast(t,'=')) />
		</cfloop>
		<!--- if a mime type is requested as part of the url ("whatever.json"), then extract that so taffy can use it --->
		<cfif numTokenValues gt numTokenNames>
			<cfset var mime = tokenValues[numTokenValues] /><!--- the last token represents ".json"/etc --->
			<cfset var mimeLen = len(mime) />
			<cfset returnData["_taffy_mime"] = right(mime, mimeLen - 1) />
		</cfif>
		<!--- return --->
		<cfreturn returnData />
	</cffunction>
	<cffunction name="throwError" access="private" output="false" returntype="void">
		<cfargument name="statusCode" type="numeric" default="500" />
		<cfargument name="msg" type="string" required="true" hint="message to return to api consumer" />
		<cfcontent reset="true" />
		<cfheader statuscode="#arguments.statusCode#" statustext="#arguments.msg#" />
		<cfabort />
	</cffunction>
	<cffunction name="cacheEndpoint" access="private" output="false" returnType="void">
		<cfargument name="cfcPath" type="string" required="true" hint="dot.notation.cfc.path" />
		<cfset var t = "" />
		<cfset application._taffy.endpointCache[arguments.cfcPath] = {} />
		<cfset application._taffy.endpointCache[arguments.cfcPath].cfc = createObject("component", arguments.cfcPath) />
		<cfset application._taffy.endpointCache[arguments.cfcPath].methods = {} />
		<cfset var tmp = getMetadata(application._taffy.endpointCache[arguments.cfcPath].cfc).functions />
		<cfloop array="#tmp#" index="t">
			<cfset application._taffy.endpointCache[arguments.cfcPath].methods[t.name] = true />
		</cfloop>
	</cffunction>
	<cfscript>
	function reFindNoSuck(string pattern, string data, numeric startPos = 1){
		var sucky = refindNoCase(pattern, data, startPos, true);
		var i = 0;
		var awesome = [];
		if (not isArray(sucky.len) or arrayLen(sucky.len) eq 0){return [];} //handle no match at all
		for (i=1; i<= arrayLen(sucky.len); i++){
			//if there's a match with pos 0 & length 0, that means the mime type was not specified
			if (sucky.len[i] gt 0 && sucky.pos[i] gt 0){
				//don't include the group that matches the entire pattern
				var matchBody = mid( data, sucky.pos[i], sucky.len[i]);
				if (matchBody neq arguments.data){
					arrayAppend( awesome, matchBody );
				}
			}
		}
		return awesome;
	}
	</cfscript>

	<!--- helper methods --->
	<cffunction name="setDefaultMime" access="private" output="false" returntype="void">
		<cfargument name="DefaultMimeType" type="string" required="true" hint="mime time to set as default for this api" />
		<cfset application._taffy.settings.defaultMime = arguments.DefaultMimeType />
	</cffunction>
	<cffunction name="setDebugKey" access="private" output="false" returnType="void">
		<cfargument name="keyName" type="string" required="true" hint="url parameter you want to use to enable ColdFusion debug output" />
		<cfset application._taffy.settings.debugKey = arguments.keyName />
	</cffunction>
	<cffunction name="setReloadKey" access="private" output="false" returnType="void">
		<cfargument name="keyName" type="string" required="true" hint="url parameter you want to use to reload Taffy (clear cache, reset settings)" />
		<cfset application._taffy.settings.reloadKey = arguments.keyName />
	</cffunction>
	<cffunction name="setReloadPassword" access="private" output="false" returnType="void">
		<cfargument name="password" type="string" required="true" hint="value required for the reload key to initiate a reload. if it doesn't match, then the framework will not reload." />
		<cfset application._taffy.settings.reloadPassword = arguments.password />
	</cffunction>
	<cffunction name="addURI" access="public" output="false" returntype="taffy.core.api">
		<cfargument name="cfcpath" type="string" required="true" hint="dot.path.to.api" />
		<cfargument name="lazyLoad" type="boolean" required="false" default="false" hint="if set to false, object will not be cached until the first time it is used" />
		<!--- get the cfc metadata that defines the uri for that cfc --->
		<cfset var uri = '' />
		<cfset var meta = '' />
		<cfif arguments.lazyLoad>
			<cfset uri = getMetaData(createObject("component", arguments.cfcpath)).taffy_uri />
		<cfelse>
			<cfset application._taffy.endpointCache[arguments.cfcPath] = createObject("component", arguments.cfcpath) />
			<cfset uri = getMetaData(application._taffy.endpointCache[arguments.cfcPath]).taffy_uri />
		</cfif>
		<cfset meta = convertURItoRegex(uri) />
		<cfset application._taffy.endpoints[meta.uriRegex] = { cfc = arguments.cfcpath , tokens = meta.tokens } />
		<cfreturn this />
	</cffunction>
	<cffunction name="registerMimeType" access="private" output="false" returntype="void">
		<cfargument name="extension" type="string" required="true" hint="ex: json" />
		<cfargument name="mimeType" type="string" required="true" hint="ex: text/json" />
		<cfset application._taffy.settings.mimeExtensions[arguments.extension] = arguments.mimeType />
		<cfset application._taffy.settings.mimeTypes[arguments.mimeType] = arguments.extension />
	</cffunction>
	<cffunction name="setDefaultRepresentationClass" access="public" output="false" returnType="void" hint="Override the global default representation object with a custom class">
		<cfargument name="customClassDotPath" type="string" required="true" hint="Dot-notation path to your custom class to use as the default" />
		<cfset application._taffy.settings.defaultRepresentationClass = arguments.customClassDotPath />
	</cffunction>

</cfcomponent>