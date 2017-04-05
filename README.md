docker run --log-driver=json-file \
  --restart=no \
  -d \
  -e DYNAMODB_TABLE=$DYNAMODB_TABLE \
  -e NODE_TYPE=$NODE_TYPE \
  -e REGION=$AWS_REGION \
  -e INSTANCE_NAME=$INSTANCE_NAME \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /usr/bin/docker:/usr/bin/docker \
  pecigonzalo/init-aws
