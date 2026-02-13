set -o errexit
# set -o nounset
set -o pipefail

#computed vars 
ENDPOINT_ID=
STACK_ID=
SWARM_ID=
HTTP_STATUS=

###########

### $1 - api path
function api_call() {
    local RES=$(curl -s --request GET --url ${PORTAINER_ENDPOINT}${1} --header "x-api-key: $PORTAINER_API_KEY")
    echo $RES
}

# $1 - method (POST/GET/PUT...)
# $2 - api path
# $3 - body
# Outputs: HTTP_STATUS_CODE<newline>BODY
function api_call_json_body() {
    local TMPFILE=$(mktemp)
    local STATUS=$(curl -s -w "%{http_code}" -o "$TMPFILE" --request $1 --url ${PORTAINER_ENDPOINT}${2} --header "x-api-key: $PORTAINER_API_KEY" --header "content-type: application/json" --data "$3")
    echo "$STATUS"
    cat "$TMPFILE"
    rm -f "$TMPFILE"
}

# $1 - endpoint name
function get_endpoint_id() {
    echo $(api_call "/api/endpoints?name=$1" | jq .[0].Id)
}

# $1 - swarm id
# $2 - stack name
function get_stack_id() {
    #echo "getting stack $1 $2"
    echo $(api_call "/api/stacks" | jq ".[] | select(.Name == \"$2\" and .SwarmId == $1) | .Id")
}

# $1 - endpoint id
function get_swarm_id() {
    echo $(api_call "/api/endpoints/$1/docker/info" | jq .Swarm.Cluster.ID);
}

# $1 - env file
function getEnvJson() {

    local ENV_JSON=""
    while read LINE || [ -n "$LINE" ]
    do
        # Skip empty lines and comments
        [[ -z "$LINE" ]] && continue
        [[ "$LINE" =~ ^[[:space:]]*# ]] && continue
        [[ ! "$LINE" =~ = ]] && continue
        
        NAME=$(echo "$LINE" | cut -d "=" -f1)
        VALUE=$(echo "$LINE" | cut -d "=" -f2-)
        VALUE_JSON=$(node -e 'console.log(JSON.stringify(process.argv[1].replace(/^"(.*)"$/g,"$1")))' "$VALUE")

        ENV_JSON="$ENV_JSON,{\"name\":\"$NAME\", \"value\": $VALUE_JSON}"
    done < "$1"

    echo '['${ENV_JSON:1}']'
}

# COMPUTE ID VARS

# find endpoint ID
ENDPOINT_ID=$(get_endpoint_id $ENDPOINT)

# find swarm ID
SWARM_ID=$(get_swarm_id $ENDPOINT_ID);

# find stack id
STACK_ID=$(get_stack_id $SWARM_ID $STACK_NAME)

# Display input vars
echo "PORTAINER_ENDPOINT=$PORTAINER_ENDPOINT"
echo "PORTAINER_API_KEY=$PORTAINER_API_KEY"
echo ""
echo "ENDPOINT=$ENDPOINT"
echo "STACK_NAME=$STACK_NAME"
echo "STACK_FILE=$STACK_FILE"
echo "STACK_ENV_FILE=$STACK_ENV_FILE"
echo ""
echo "ENDPOINT_ID=$ENDPOINT_ID";
echo "SWARM_ID=$SWARM_ID";
echo "STACK_ID=$STACK_ID";
echo ""

# load stack file
STACK_FILE_STRING=$(node -e "fs=require('fs');console.log(JSON.stringify(fs.readFileSync('$STACK_FILE').toString()))")
echo "STACK_FILE_STRING=$STACK_FILE_STRING"
echo ""
echo ""
echo "cat $STACK_ENV_FILE"
cat $STACK_ENV_FILE
echo "======================================="
echo ""
echo ""

# load env file 

# check if stack is already deployed
if [ -z "$STACK_ID" ]
then
    # create stack
    echo "It seems $STACK_NAME stack was not deployed yet on $ENDPOINT cluster. Creating it...";

    # type=1 means swarm stack, method=string means inline stack file content
    URL="/api/stacks/create/swarm/string?endpointId=$ENDPOINT_ID"
    PAYLOAD='{"env": '$(getEnvJson $STACK_ENV_FILE)',"fromAppTemplate":false, "name": "'$STACK_NAME'","swarmID": '$SWARM_ID', "stackFileContent": '${STACK_FILE_STRING}'}'
    echo "=== PAYLOAD ===";
    echo "POST $URL"
    echo "$PAYLOAD" | jq .
    echo "===============";
    echo ""
    API_RESULT=$(api_call_json_body POST $URL "$PAYLOAD")
    HTTP_STATUS=$(echo "$API_RESULT" | head -n 1)
    RESPONSE=$(echo "$API_RESULT" | tail -n +2)
    echo "=== RESPONSE ==="
    echo "HTTP Status: $HTTP_STATUS"
    echo "Body:"
    echo "$RESPONSE" | jq . 2>/dev/null || echo "$RESPONSE"
    echo "================"

else
    # update stack
    echo "Updating $STACK_NAME stack from $ENDPOINT cluster..."

    URL="/api/stacks/$STACK_ID?endpointId=$ENDPOINT_ID"
    PAYLOAD='{"env": '$(getEnvJson $STACK_ENV_FILE)',"prune": true,"pullImage": true,"stackFileContent":'${STACK_FILE_STRING}'}'
    echo "=== PAYLOAD ===";
    echo "PUT $URL"
    echo "$PAYLOAD" | jq .
    echo "===============";
    echo ""
    API_RESULT=$(api_call_json_body PUT $URL "$PAYLOAD")
    HTTP_STATUS=$(echo "$API_RESULT" | head -n 1)
    RESPONSE=$(echo "$API_RESULT" | tail -n +2)
    echo "=== RESPONSE ==="
    echo "HTTP Status: $HTTP_STATUS"
    echo "Body:"
    echo "$RESPONSE" | jq . 2>/dev/null || echo "$RESPONSE"
    echo "================"
fi

# Check HTTP status code
if [ -z "$HTTP_STATUS" ]; then
    echo ""
    echo "ERROR: Failed to get HTTP status from Portainer API (curl may have failed)"
    echo "Response: $RESPONSE"
    exit 1
fi

if [ "$HTTP_STATUS" -lt 200 ] 2>/dev/null || [ "$HTTP_STATUS" -ge 300 ] 2>/dev/null; then
    echo ""
    echo "ERROR: Portainer API returned HTTP $HTTP_STATUS"
    if echo "$RESPONSE" | jq -e '.message' > /dev/null 2>&1; then
        echo "Message: $(echo "$RESPONSE" | jq -r '.message')"
    fi
    if echo "$RESPONSE" | jq -e '.details' > /dev/null 2>&1; then
        echo "Details: $(echo "$RESPONSE" | jq -r '.details')"
    fi
    exit 1
fi

# Check for error in response body (some errors return 200 with error message)
if echo "$RESPONSE" | jq -e '.message' > /dev/null 2>&1; then
    # Check if it's actually an error (has err or error field, or message without Id)
    if echo "$RESPONSE" | jq -e '.err // .error' > /dev/null 2>&1 || ! echo "$RESPONSE" | jq -e '.Id' > /dev/null 2>&1; then
        echo ""
        echo "ERROR: Portainer API returned an error:"
        echo "$RESPONSE" | jq -r '.message'
        exit 1
    fi
fi

echo ""
echo "Stack deployed successfully!"  
