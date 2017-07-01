# Docker Swarm for AWS Init
Initializes Docker Swarm cluster members

*Example project:* **[Terraform docker-swarm](https://github.com/pecigonzalo/tf-docker-swarm)**

### Description
This container will initialize the Docker Swarm if the first node or will perform actions to join the cluster if it detects and existing node.
It will interact with the DynamoDB to discover the primary manager and using the [docker-meta-aws](https://github.com/pecigonzalo/docker-meta-aws) service get its corresponding token to join.

### Usage
##### Paramaters
| Parameter | Example | Description |
|-----------|:-------:|:------------|
| DYNAMODB_TABLE | - | DynamodDB table ID |
| NODE_TYPE | worker / manager | Role of the node we are running on |
| REGION | eu-central-1 | AWS Region ID|

##### Example
```
docker run -d \
  --restart=no \
  -e DYNAMODB_TABLE=$DYNAMODB_TABLE \
  -e NODE_TYPE=$NODE_TYPE \
  -e REGION=$AWS_REGION \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /usr/bin/docker:/usr/bin/docker \
  pecigonzalo/init-aws
```
