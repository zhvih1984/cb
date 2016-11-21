## Deploying and destroying the HTTP service

#### Prepare you machine for working with AWS

1. Install AWS's CLI tools by following http://docs.aws.amazon.com/cli/latest/userguide/installing.html

2. Place your AWS access and secret keys in the environment:

  ```
  export AWS_ACCESS_KEY_ID=[your access key here]
  export AWS_SECRET_ACCESS_KEY=[your secret key here]
  ```

#### Deploy the HTTP auto-scaling service

1. Set service configuration:

  * `REGION` - the AWS region in which to create the service (e.g. `us-east-1`, `us-west-2`, etc)
  * `AMI_ID` - the ID of the CoreOS AMI that you want to use. The AMI must correspond to the region and must be of `HVM64` type.
  * `SSH_KEY_NAME` - the name of the Key Pair with which you will be able to SSH into the servers
  * Optionally, you can override `STACK_NAME` (defaults to `username-YYYYMMDD-hhmmss`). It is used as CloudFormation stack name and as prefix for the name of most AWS resources.

  ```
  REGION=us-west-2
  AMI_ID=ami-7e35981e
  SSH_KEY_NAME=oregon
  STACK_NAME="$(whoami)-$(date +"%Y%m%d-%H%M%S")"
  ```

2. Create the service:

  ```
  aws cloudformation create-stack --template-body file://cf-template.json --region $REGION --stack-name $STACK_NAME --parameters ParameterKey=AmiId,ParameterValue=$AMI_ID ParameterKey=SshKeyName,ParameterValue=$SSH_KEY_NAME
  ```

3. Track the deployment progress and get the URL of the HTTP service:

  ```
  aws cloudformation describe-stacks --region $REGION --stack-name $STACK_NAME
  ```

  The above command outputs the status of the deploy. There are 2 interesting pieces of information:

    * The `StackStatus` property shows the status of the deploy (e.g. `CREATE_IN_PROGRESS`). Once the service is deployed, `StackStatus` will change to `CREATE_COMPLETE`.
    * The `URL` output variable (look for `"OutputKey": "URL"`) will show the URL you can use to access the HTTP service, once the deploy is complete.

#### Destroy the HTTP auto-scaling service

Once you are done using the service deployed in the previous step, destroy it with the following command (do not forget to set your AWS keys in the environment):

  ```
  aws cloudformation delete-stack --region $REGION --stack-name $STACK_NAME
  ```

## Using the HTTP service

* A GET request on `/` returns a 200 response with content `Hi`.

  Example:

  ```
  $ curl -v http://URL
  ...
  HTTP/1.1 200 OK
  ...
  Hi
  ```

* A POST request on `/add_public_key` adds a public key to the list of authorized keys for the `core` user. It requires:
  * Basic HTTP authentication with username `admin` and password `secret`
  * A JSON object with a `ssh_public_key` property which contains a Base64-encoded representation of the public key

  Example:

  ```
  $ BASE64_PUB_KEY="$(cat ~/.ssh/id_rsa.pub | base64)"
  $ curl -XPOST --user admin:secret http://URL/add_public_key -d "{\"ssh_public_key\": \"$BASE64_PUB_KEY\"}"
  Key successfully saved:
  ssh-rsa AAAAB3NzaC1....
  ```

* The HTTP service scales automatically up and down in relation to the number of requests submitted in the last minute:

  * under 20 - cluster size decreases by 1 (until there is 1 server left)
  * 20-40 - cluster size stays the same
  * above 40 - cluster size increases by 1 (until there are 5 servers)

## Updating the HTTP service

To deploy an updated HTTP service, you need to:

1. Update `http_server.rb` and potentially add more files (e.g. CSS, JavaScript, etc)
2. Update `Dockerfile` to create a Docker image with your updates (e.g. include new files)
3. Build and push the Docker image to a public Docker Hub repository with `docker build -t repo:tag .` and `docker push repo:tag`
4. Set the optional `DockerImage` parameter to the name of your image when deploying:

  ```
  aws cloudformation create-stack --template-body file://cf-template.json --region $REGION --stack-name $STACK_NAME --parameters ParameterKey=AmiId,ParameterValue=$AMI_ID ParameterKey=SshKeyName,ParameterValue=$SSH_KEY_NAME ParameterKey=DockerImage,ParameterValue=repo:tag
  ```

  or when updating:

  ```
  aws cloudformation update-stack --template-body file://cf-template.json --region $REGION --stack-name $STACK_NAME --parameters ParameterKey=AmiId,ParameterValue=$AMI_ID ParameterKey=SshKeyName,ParameterValue=$SSH_KEY_NAME ParameterKey=DockerImage,ParameterValue=repo:tag
  ```

## Technical discussion

#### Provisioning tool

Managing AWS resources with API calls is possible but difficult, especially when a deployment needs to be converged to a desired state. This is why I use a tool that automates that process.

Even though I have a lot of experience with Terraform, I picked CloudFormation for a few reasons:

  * It uses the AWS CLI, which makes it easy to pick up for users who already have it and use it. Terraform is a separate tool with a different usage lifecycle (`plan`, `apply`, `destroy`).
  * CloudFormation stores the state within AWS, therefore allowing a user to update or destroy infrastructure created by someone else. Terraform stores the state locally and therefore requires additional plumbing to synchronize it to a central location.
  * CloudFormation is driven by AWS, therefore the operation will not be interrupted if the user goes offline. Terraform runs locally and requires the user to stay online.
  * I had never used CloudFormation, and this was a good opportunity to get some exposure.

#### VPC creation

I chose to create a new VPC and subnet for each deploy for 2 reasons:

  * By isolating deploys at the network level, we force the formalization of any external dependencies (e.g. an LDAP server shared between all deployments)
  * It ties together a large part of the deploy, making it clear who the owner is, and prevents expensive resources like instances from being left behind after a deploy is destroyed.

#### Validation of reachability

In order to make sure that the first server comes up, I use CloudFormation's signaling capability - this way if the HTTP server does not come online, the deploy will fail. I think this is a better strategy than silent failure as when a deploy contains smaller, supporting services, the user may not always notice that they failed to start.

#### HTTP server

I wrote the HTTP server in Ruby because I wanted to get some exposure with it, as this is a core technology.

The server is baked into a Docker image for ease of deployment. It runs as an unprivileged user because I think this makes things a bit safer in case a vulnerability within Docker or the kernel (e.g. cgroups) is discovered.

For the injection of the SSH public key I ultimately chose the easiest solution - mount the `.ssh` directory, append the key to the `authorized_keys` file and place a file in the `authorized_keys.d` directory. The last action ensures that the key will still be present after a reboot. In order to be able to write to the mounted directory, the HTTP server user and group within Docker need to match the IDs from the host. Therefore, the container uses optional `USER_ID` and `GROUP_ID` environment variables to run the HTTP server process under.

In the process of injecting the SSH public key, I considered 2 other solutions:

* Call `update-ssh-keys` on the host. However, I did not want to go against the spirit of CoreOS with a non-Dockerized service.
* Call `update-ssh-keys` within the container on the mounted `.ssh` directory. I wanted to mount `update-ssh-keys` from the host, in case implementation details change. However, the tool has a few dependencies (e.g. `ssh-keygen`) and I thought adjusting the Docker image to the implementation details is sub-optimal.

#### Security considerations

###### SSH public key injection

When security is concerned, a pull model is much better than a push one. In a production environment, I would design a service where the individual servers set accepted keys as a result of changes to an external data repository. An example would be a per-instance record in `etcd`, which is watched for changes. This can be hardened with logging, alerts and an approval/validation flow.

###### SSL

Even for dev/test deploys, I would add a domain in Route53 and use a pre-configured SSL key in ELB to protect all traffic. Direct access to port 80 on the servers could also be forbidden at the security group level.

###### Build our own `cfn-signal` Docker image

I used a public Docker image with the `cfn-signal` tool (`crewjam/awscli`). This is a security risk. In a production deploy, I would build and host this image internally.

###### Access

The current service is accessible from anywhere. Non-public services should stay non-public even during development. That means either using VPN or Direct Connect to AWS, or at least restricting access via security groups.

#### Availability considerations

###### CoreOS upgrades

For this test, I switched off automatic restarting on upgrades. In a production environment, I would set up fleet-wide `etcd`/`locksmith` so that instances can reboot one by one for upgrades.

###### Service upgrades

In production, I would add an `UpdatePolicy` on the `AutoScalingGroup` CloudFormation template to specify an upgrade strategy (e.g. rolling upgrade where we keep a specific capacity up while new servers are started).

###### Monitoring

It would be nice to have a notification (e.g. email) to the user on stack success/failure.

In production, I would add monitoring and alarms to both ELB and the Auto Scaling Group in order to detect and respond (preferably automatically) to issues.

###### Auto-scaling based on real metrics

The current auto-scaling is very primitive. For a more stable deploy, I would trigger auto-scaling based on factors that include at least CPU usage, network traffic, response time, and number of errors.

###### Logging

In production, I would send logs on the fly to a central location and use them for detecting and alerting about issues, aiding in troubleshooting, and auditing.

#### Workflow considerations

###### Run from a CI/CD tool

In order to keep a record of who triggered what deploy, when and have an approval flow (e.g. for production deploys), I would move this job to a CI/CD service like Jenkins and integrate it with the overall development workflow.

###### Use specific HTTP service container tag instead of `latest`

Linked to the CI/CD point, I would design the workflow so that CI/CD pushes the Docker image with a descriptive tag (e.g. containing the Git branch name). The deployment will then use that tag rather than `latest`.

#### Performance considerations

###### Pre-bake an AMI

If the Docker container becomes too large and the Auto Scaling Group frequently adjusts the number of servers, I would create an AMI with everything inside, so that new instances start faster.
