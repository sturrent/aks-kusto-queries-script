#!/bin/bash

# v0.2.3
# Script to generate kusto file with common queries for a cluster
# The .kql file is created inside the aks-kusto-queries directory
# sergio.turrent@microsoft.com

# vars
SCRIPT_PATH="$( cd "$(dirname "$0")" ; pwd -P )"
SCRIPT_NAME="$(echo $0 | sed 's|\.\/||g')"

# Argument validation
if [ "$#" -ne 1 ]; then
    echo -e "only the cluster URI is expected...\n"
    echo -e "Usage: bash ${SCRIPT_PATH}/${SCRIPT_NAME} <AKS_CLUSTER_URI>\n"
	exit 1
fi

# URI validation
URI_STRING=$1
SLASH_COUNT=$(echo $URI_STRING | tr -dc "/" | wc -m)

if [ $SLASH_COUNT != 8 ]; then
	echo -e "\nError: cluster URI does not have the expected format...\n"
    echo -e "Usage: bash ${SCRIPT_PATH}/${SCRIPT_NAME} <AKS_CLUSTER_URI>\n"
	exit 1
fi

mkdir -p ${SCRIPT_PATH}/aks-kusto-queries 2> /dev/null

# Extracting info from URI
SUBSCRIPTION_ID=$(echo $URI_STRING | awk -F'/' '{print $3}')
RESOURCEGROUP_NAME=$(echo $URI_STRING | awk -F'/' '{print $5}')
RESOURCE_NAME=$(echo $URI_STRING | awk -F'/' '{print $NF}')

printf "\n// Here’s are ALL the errors/messages for the AKS clusters in the resource group in the past 90 days -
union cluster(\"Aks\").database(\"AKSprod\").FrontEndContextActivity, cluster(\"Aks\").database(\"AKSprod\").AsyncContextActivity
| where subscriptionID contains \"$SUBSCRIPTION_ID\"
| where resourceName contains \"$RESOURCE_NAME\"
| where level != \"info\"
| where PreciseTimeStamp > ago(90d)
| project PreciseTimeStamp, operationID, correlationID, level, suboperationName, msg


// Here’s are the recent scale/upgrade operations – 
union cluster(\"Aks\").database(\"AKSprod\").FrontEndContextActivity, cluster(\"Aks\").database(\"AKSprod\").AsyncContextActivity
| where subscriptionID contains \"$SUBSCRIPTION_ID\"
| where resourceName contains \"$RESOURCE_NAME\"
| where msg contains \"intent\" or msg contains \"Upgrading\" or msg contains \"Successfully upgraded cluster\" or msg contains \"Operation succeeded\" or msg contains \"validateAndUpdateOrchestratorProfile\" // or msg contains \"unique pods in running state\"
| where PreciseTimeStamp > ago(90d)
| project PreciseTimeStamp, operationID, correlationID, level, suboperationName, msg

// Shows the scale errors/messages for an AKS cluster using the operationID from the previous query
union cluster(\"Aks\").database(\"AKSprod\").FrontEndContextActivity, cluster(\"Aks\").database(\"AKSprod\").AsyncContextActivity
| where operationID == \"\"
| where level != \"info\"
| project PreciseTimeStamp, level, msg

//Black box monitoring FIND fqdn by customer\"s subscriptionID
cluster(\"aks\").database(\"AKSprod\").BlackboxMonitoringActivity
| where subscriptionID == \"$SUBSCRIPTION_ID\" and resourceGroupName contains \"$RESOURCEGROUP_NAME\"
| where PreciseTimeStamp > ago(9d)
| summarize by fqdn, resourceGroupName, resourceName, underlayName

//Black box monitoring using fqdn to find where cluster is not healthy
cluster(\"aks\").database(\"AKSprod\").BlackboxMonitoringActivity
| where fqdn == \"replacefqdn\"
// | where ([\"state\"] != \"Healthy\" or podsState != \"Healthy\" or resourceState != \"Healthy\" or addonPodsState != \"Healthy\")
| where PreciseTimeStamp > ago(20d)
| project fqdn, PreciseTimeStamp, agentNodeName, state, reason, podsState, resourceState, addonPodsState, agentNodeCount, provisioningState, msg, resourceGroupName, resourceName, underlayName  
// | order by PreciseTimeStamp asc
// | render timepivot by fqdn, reason, agentNodeName, addonPodsState
| render timepivot by fqdn, agentNodeName, addonPodsState, reason  
// | summarize count() by reason 
// | sort by reason

//Black box monitoring for cluster  
cluster(\"aks\").database(\"AKSprod\").BlackboxMonitoringActivity
| where PreciseTimeStamp > ago(12h) and underlayName == \"\"
| where reason != \"\"
| summarize count() by reason | top 10 by count_ desc

// Find Errors reported by ARM Failed - Deleted - Created 
cluster(\"ARMProd\").database(\"ARMProd\").EventServiceEntries 
| where subscriptionId == \"$SUBSCRIPTION_ID\"
| where resourceUri contains \"$RESOURCE_NAME\"
| where TIMESTAMP > ago(3d)
| where status == \"Failed\" 
| project PreciseTimeStamp, correlationId , operationId, operationName, properties

// Get serviceRequestId of processes sent to cluster
cluster(\"ARMProd\").database(\"ARMProd\").HttpOutgoingRequests
| where httpMethod != \"GET\"
| where TIMESTAMP > ago(1d)
| where targetUri contains \"$RESOURCE_NAME\"// and targetUri contains \"$SUBSCRIPTION_ID\"
| project TIMESTAMP, ActivityId, serviceRequestId , clientRequestId, failureCause, httpMethod , operationName, targetUri

//  Use the activityID from the previous query.
cluster(\"Azcrp\").database(\"crp_allprod\").ContextActivity 
| where TIMESTAMP between (datetime(2018-08-17T07:57Z)..datetime(2018-08-17T09:28Z)) 
| where subscriptionId == \"$SUBSCRIPTION_ID\"
// | where activityId == \"3817a3d4-7045-4db5-bc7f-45dbffe2166a\" 
// | where message contains \"$RESOURCE_NAME\"
// | where PreciseTimeStamp > ago(3d) // datetime(2018-07-31)
| project PreciseTimeStamp, activityId, traceLevel, message

// claims name shows WHO requested or performed the action
cluster(\"ARMProd\").database(\"ARMProd\").EventServiceEntries 
| where subscriptionId == \"$SUBSCRIPTION_ID\"
| where resourceUri contains \"$RESOURCE_NAME\"
// | where claims contains \"1d78a85d-813d-46f0-b496-dd72f50a3ec0\"
// | where ActivityId == \"3817a3d4-7045-4db5-bc7f-45dbffe2166a\"
// | where operationName contains \"delete\"
| where TIMESTAMP between (datetime(2018-08-17T07:57Z)..datetime(2018-08-17T09:28Z)) 
// | where claims contains \"baead28c-2ce7-4550-83a5-5e6a2deb02b8\"
// | where status == \"Failed\" 
| project PreciseTimeStamp, claims, authorization, properties, resourceUri, operationName //, httpRequest, correlationId, operationId, Deployment, operationName
// | project PreciseTimeStamp, resourceUri  , issuer, issuedAt  

// Get the PUT operation. This query also shows the command used (aks get-credentials, browse, scale, show, create)
cluster(\"Armprod\").database(\"ARMProd\").HttpIncomingRequests
| where subscriptionId == \"$SUBSCRIPTION_ID\" 
| where targetUri contains \"$RESOURCE_NAME\"
// | where authorizationAction contains \"write\" or authorizationAction contains \"delete\"
| where commandName contains \"aks\" and httpMethod == \"PUT\" 
| where PreciseTimeStamp > ago(3d) 
| project TIMESTAMP,httpMethod,commandName,failureCause,serviceRequestId,authorizationAction,errorCode,errorMessage,subscriptionId,correlationId,targetUri

// Get the PUT operation
cluster(\"Armprod\").database(\"ARMProd\").HttpIncomingRequests
| where subscriptionId == \"$SUBSCRIPTION_ID\"
| where targetUri contains \"$RESOURCE_NAME\" and authorizationAction contains \"Clusters\"
| where httpMethod == \"PUT\"
| where PreciseTimeStamp > ago(3d) // between (datetime(2018-07-16) .. datetime(2018-07-20))
| project TIMESTAMP,  commandName , serviceRequestId , httpMethod  , authorizationAction , operationName

// 
cluster(\"Aks\").database(\"AKSprod\").FrontEndQoSEvents
| where subscriptionID contains \"$SUBSCRIPTION_ID\"
| where resourceName contains \"$RESOURCE_NAME\"
// | where operationName !contains \"delete\"
| where PreciseTimeStamp > ago(3d)
// feature-gates will be broken when upgrading to 1.11.0+ Please code all cases against - 2835281 - for this issue (also added in the wiki)
// Chase has created doc for scenario where upgrade failing to 1.11 and nodes getting disappear. Here is the doc: https://www.csssupportwiki.com/index.php/curated:Azure/Virtual_Machine/Products/Azure_Kubernetes_Service/TSG/upgrade_to_1.11_NodesNotReady 
// Customer can run this script on nodes which are missing
// az vm run-command invoke -g  -n  --command-id RunShellScript --scripts \"sed -i \"s/--feature-gates=Accelerators=true //\" /etc/default/kubelet && systemctl daemon-reload && systemctl restart kubelet\"
// But a roll is being fixed out , once fix has been rolled out they can retry the upgrade

cluster(\"Aks\").database(\"AKSprod\").AsyncQoSEvents
| where subscriptionID == \"$SUBSCRIPTION_ID\"
| where TIMESTAMP > ago(3d)
| where suboperationName == \"Upgrading\" and propertiesBag contains \"1.11\"
| extend bag = parse_json(propertiesBag)
| extend from_version = tostring(bag.k8sCurrentVersion)
| extend to_version = tostring(bag.k8sGoalVersion)
| where from_version !contains \"1.11\" and to_version contains \"1.11\" and resultCode == \"NodesNotReady\"

//Black box monitoring for cluster  
cluster(\"aks\").database(\"AKSprod\").BlackboxMonitoringActivity
| where PreciseTimeStamp > ago(1d)
| where fqdn contains \"replacefqdn\"
// | where [\"state\"] == \"Unhealthy\"
| summarize count(state) by bin(PreciseTimeStamp, 5min), state
| render timeline

//Black box monitoring for cluster  
cluster(\"aks\").database(\"AKSprod\").BlackboxMonitoringActivity
| where PreciseTimeStamp > ago(1d) 
| where fqdn contains \"replacefqdn\"
| where state != \"Healthy\"
| project PreciseTimeStamp, state, provisioningState, reason, agentNodeCount, msg, resourceGroupName, resourceName, underlayName 
| order by PreciseTimeStamp asc
// | render timeline     

// 429 throttling (incoming requests)
cluster(\"Armprod\").database(\"ARMProd\").HttpIncomingRequests
| where subscriptionId  == \"$SUBSCRIPTION_ID\"  
| where TIMESTAMP >= now(-2d)  
| where httpStatusCode == 429  
| summarize count() by bin(TIMESTAMP, 1d), operationName, clientApplicationId, clientIpAddress 
| order by count_ desc

// 429 throttling (all operations)
cluster(\"Armprod\").database(\"ARMProd\").HttpIncomingRequests
| where subscriptionId  == \"$SUBSCRIPTION_ID\"                   
| where TIMESTAMP >= now(-2d)  
| where httpStatusCode != -1

// 429 throttling (outgoing requests)
cluster(\"Armprod\").database(\"ARMProd\").HttpOutgoingRequests
| where subscriptionId  == \"$SUBSCRIPTION_ID\"
| where TIMESTAMP >= now(-2d)  
| where httpStatusCode == 429 
| summarize count() by hostName 
| order by count_ desc

cluster(\"Aks\").database(\"AKSprod\").AsyncQoSEvents | sample 10\n" > ${SCRIPT_PATH}/aks-kusto-queries/MC_${RESOURCEGROUP_NAME}_${RESOURCE_NAME}.kql

printf "\nKusto queries for the cluster have been save in:\n\t${SCRIPT_PATH}/aks-kusto-queries/MC_${RESOURCEGROUP_NAME}_${RESOURCE_NAME}.kql
\nIf you are using Windows subsystem layer you can get to that path from %%userprofile%%\\AppData\\Local\\Packages and look for the distribution folder
\texample for Ubuntu: CanonicalGroupLimited.UbuntuonWindows_79rhkp1fndgsc\n
\nThen look for \"LocalState - rootfs\"
format C:\\\Users\\NAME\\AppData\\Local\\Packages\\DISTRO_FOLDER\\LocalState\\\rootfs\n\n"

exit 0
