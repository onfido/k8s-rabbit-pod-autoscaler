#!/bin/bash

notifySlack() {
  if [ -z "$SLACK_HOOK" ]; then
    return 0
  fi

  curl -s -X POST --data-urlencode 'payload={"text": "'"$1"'"}' $SLACK_HOOK > /dev/null
}

autoscalingNoWS=$(echo "$AUTOSCALING" | tr -d "[:space:]")
IFS=';' read -ra autoscalingArr <<< "$autoscalingNoWS"

while true; do
  for autoscaler in "${autoscalingArr[@]}"; do
    IFS='|' read minPods maxPods mesgPerPod namespace deployment queueName <<< "$autoscaler"

    queueMessages=$(curl -s -u $RABBIT_USER:$RABBIT_PASS $RABBIT_HOST:15672/api/queues/%2f/$queueName | jq '.messages')

    if [[ $queueMessages != "" ]]; then
      requiredPods=$(echo "$queueMessages/$mesgPerPod" | bc 2> /dev/null)

      if [[ $requiredPods != "" ]]; then
        currentPods=$(kubectl -n $namespace describe deploy $deployment 2> /dev/null | \
          grep desired | awk '{print $2}' | head -n1)

        if [[ $currentPods != "" ]]; then
          if [[ $requiredPods -ne $currentPods ]]; then
            desiredPods=""

            if [[ $requiredPods -le $minPods ]]; then
              desiredPods=$minPods
            elif [[ $requiredPods -ge $maxPods ]]; then
              desiredPods=$maxPods
            else
              desiredPods=$requiredPods
            fi

            kubectl scale -n $namespace --replicas=$desiredPods deployment/$deployment 1> /dev/null

            if [[ $? -eq 0 ]]; then
              echo "Scaled $deployment to $desiredPods pods ($queueMessages msg in RabbitMQ)"
              notifySlack "Scaled $deployment to $desiredPods pods ($queueMessages msg in RabbitMQ)"
            else
              echo "Failed to scale $deployment pods."
              notifySlack "Failed to scale $deployment pods."
            fi
          fi
        else
          echo "Failed to get current pods number for $deployment."
          notifySlack "Failed to get current pods number for $deployment."
        fi
      else
        echo "Failed to calculate required pods for $deployment."
        notifySlack "Failed to calculate required pods for $deployment."
      fi
    else
      echo "Failed to get queue messages from $RABBIT_HOST for $deployment."
      notifySlack "Failed to get queue messages from $RABBIT_HOST for $deployment."
    fi

    sleep 3
  done

  sleep $INTERVAL
done
