#!/bin/bash

namespace=""
deployment=""

function getCurrentPods() {
  # Retry up to 5 times if kubectl fails
  for i in $(seq 5); do
    current=$(kubectl -n $namespace describe deploy $deployment | \
      grep desired | awk '{print $2}' | head -n1)

    if [[ $current != "" ]]; then
      echo $current
      return 0
    fi

    sleep 3
  done

  echo ""
}

function notifySlack() {
  if [ -z "$SLACK_HOOK" ]; then
    return 0
  fi

  curl -s --retry 3 --retry-delay 3 -X POST --data-urlencode 'payload={"text": "'"$1"'"}' $SLACK_HOOK > /dev/null
}

autoscalingNoWS=$(echo "$AUTOSCALING" | tr -d "[:space:]")
IFS=';' read -ra autoscalingArr <<< "$autoscalingNoWS"

while true; do
  for autoscaler in "${autoscalingArr[@]}"; do
    IFS='|' read minPods maxPods mesgPerPod namespace deployment queueName <<< "$autoscaler"

    queueMessagesJson=$(curl -s -S --retry 3 --retry-delay 3 -u $RABBIT_USER:$RABBIT_PASS \
      $RABBIT_HOST:15672/api/queues/%2f/$queueName)

    if [[ $? -eq 0 ]]; then
      queueMessages=$(echo $queueMessagesJson | jq '.messages')
      requiredPods=$(echo "$queueMessages/$mesgPerPod" | bc 2> /dev/null)

      if [[ $requiredPods != "" ]]; then
        currentPods=$(getCurrentPods)

        if [[ $currentPods != "" ]]; then
          if [[ $requiredPods -ne $currentPods ]]; then
            desiredPods=""
            # Flag used to prevent scaling down or up if currentPods are already min or max respectively.
            scale=0

            if [[ $requiredPods -le $minPods ]]; then
              desiredPods=$minPods

              # If currentPods are already at min, do not scale down
              if [[ $currentPods -eq $minPods ]]; then
                scale=1
              fi
            elif [[ $requiredPods -ge $maxPods ]]; then
              desiredPods=$maxPods

              # If currentPods are already at max, do not scale up
              if [[ $currentPods -eq $maxPods ]]; then
                scale=1
              fi
            else
              desiredPods=$requiredPods
            fi

            if [[ $scale -eq 0 ]]; then
              # To slow down the scale-down policy, scale down in steps (reduce 10% on every iteration)
              if [[ $desiredPods -lt $currentPods ]]; then
                desiredPods=$(awk "BEGIN { print int( ($currentPods - $desiredPods) * 0.9 + $desiredPods ) }")
              fi

              kubectl scale -n $namespace --replicas=$desiredPods deployment/$deployment 1> /dev/null

              if [[ $? -eq 0 ]]; then
                # Adjust logging and Slack notifications based on LOGS env and desiredPods number
                log=false
                avgPods=$(awk "BEGIN { print int( ($minPods + $maxPods) / 2 ) }")

                if [[ $LOGS == "HIGH" ]]; then
                  log=true
                elif [[ $LOGS == "MEDIUM" && ($desiredPods -eq $minPods || $desiredPods -eq $avgPods || $desiredPods -eq $maxPods) ]]; then
                  log=true
                elif [[ $LOGS == "LOW" && ($desiredPods -eq $minPods || $desiredPods -eq $maxPods) ]]; then
                  log=true
                fi

                if $log ; then
                  echo "$(date) -- Scaled $deployment to $desiredPods pods ($queueMessages msg in RabbitMQ)"
                  notifySlack "Scaled $deployment to $desiredPods pods ($queueMessages msg in RabbitMQ)"
                fi
              else
                echo "$(date) -- Failed to scale $deployment pods."
                notifySlack "Failed to scale $deployment pods."
              fi
            fi
          fi
        else
          echo "$(date) -- Failed to get current pods number for $deployment."
          notifySlack "Failed to get current pods number for $deployment."
        fi
      else
        echo "$(date) -- Failed to calculate required pods for $deployment."
        notifySlack "Failed to calculate required pods for $deployment."
      fi
    else
      echo "$(date) -- Failed to get queue messages from $RABBIT_HOST for $deployment."
      notifySlack "Failed to get queue messages from $RABBIT_HOST for $deployment."
    fi
  done

  sleep $INTERVAL
done
