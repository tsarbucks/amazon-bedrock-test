#!/usr/bin/env bash

DEFAULT_STACK_NAME="llm-lex-chatbot"
VERSION=""
CF_STACK_NAME="${DEFAULT_STACK_NAME}"

# Parse named parameters
while [ $# -gt 0 ]; do
  case "$1" in
    --version=*)
      VERSION="${1#*=}"
      CF_STACK_NAME="${DEFAULT_STACK_NAME}-${VERSION}"
      shift
      ;;
    *)
      COMMAND="$1"
      shift
      ;;
  esac
done

get_account_params() {
  ACCOUNT_ID=$(aws sts get-caller-identity \
      --query 'Account' --output text)
  STACK_REGION=$(aws configure get region)
}

docker_login() {
    aws ecr get-login-password --region ${STACK_REGION} | docker login --username AWS --password-stdin ${ACCOUNT_ID}.dkr.ecr.${STACK_REGION}.amazonaws.com
}

ecr_create_repo() { 
    aws ecr create-repository --repository-name ${CF_STACK_NAME} --image-scanning-configuration scanOnPush=true --image-tag-mutability MUTABLE
}

ecr_delete_repo() {
    aws ecr delete-repository --repository-name ${CF_STACK_NAME} --force
}

lambda_create_image() {
  docker build . -t ${CF_STACK_NAME}:test -f lambda/Dockerfile --platform=linux/amd64
  docker tag ${CF_STACK_NAME}:test ${ACCOUNT_ID}.dkr.ecr.${STACK_REGION}.amazonaws.com/${CF_STACK_NAME}:latest
  docker push ${ACCOUNT_ID}.dkr.ecr.${STACK_REGION}.amazonaws.com/${CF_STACK_NAME}:latest
}

lambda_update_function_image() {
  aws lambda update-function-code \
            --function-name ChatbotOrchestratorFunction \
            --image-uri ${ACCOUNT_ID}.dkr.ecr.${STACK_REGION}.amazonaws.com/${CF_STACK_NAME}:latest
}

check_for_function_exit_code() {
  EXIT_CODE="$1"
  MSG="$2"

  if [[ "$?" == "${EXIT_CODE}" ]]
  then
    echo "${MSG}"
  else
    echo "Error occured. Please verify your configurations and try again."
  fi
}

verify_ecr_image() {
  # Try to describe the image to see if it exists
  aws ecr describe-images \
    --repository-name ${CF_STACK_NAME} \
    --image-ids imageTag=latest \
    --region ${STACK_REGION} > /dev/null 2>&1
  
  return $?
}

case "$COMMAND" in
    init-env)
      get_account_params
      ecr_create_repo
      ;;
    build-deploy-lambda)
      get_account_params
      docker_login
      lambda_create_image
      lambda_update_function_image
      ;;
    cf-create-stack)
      get_account_params
      docker_login
      
      echo "Building and deploying Lambda image in region ${STACK_REGION}."
      lambda_create_image
      
      echo "Waiting for Lambda image to be available in ECR..."
      RETRY_COUNT=0
      while ! verify_ecr_image && [ $RETRY_COUNT -lt 30 ]; do
        sleep 2
        RETRY_COUNT=$((RETRY_COUNT + 1))
      done
      
      if [ $RETRY_COUNT -eq 30 ]; then
        echo "Error: Timed out waiting for Lambda image to be available in ECR"
        exit 1
      fi

      echo "Creating CloudFormation Stack in region ${STACK_REGION}."
        STACK_ID=$(aws cloudformation create-stack \
          --stack-name ${CF_STACK_NAME} \
          --template-body file://cloudformation/infrastructure.yaml \
          --parameters ParameterKey=LambdaImage,ParameterValue=${ACCOUNT_ID}.dkr.ecr.${STACK_REGION}.amazonaws.com/${CF_STACK_NAME}:latest \
          --capabilities CAPABILITY_NAMED_IAM \
          --query 'StackId' --output text)

        aws cloudformation wait stack-create-complete \
          --stack-name ${STACK_ID}

        check_for_function_exit_code "$?" "Successfully created CloudFormation stack."
      ;;
    cf-update-stack)
      get_account_params
      docker_login
      
      STACK_ID=$(aws cloudformation update-stack \
        --stack-name ${CF_STACK_NAME} \
        --template-body file://cloudformation/infrastructure.yaml \
        --parameters ParameterKey=LambdaImage,ParameterValue=${ACCOUNT_ID}.dkr.ecr.${STACK_REGION}.amazonaws.com/${CF_STACK_NAME}:latest \
        --capabilities CAPABILITY_NAMED_IAM \
        --query 'StackId' --output text)

      aws cloudformation wait stack-update-complete \
        --stack-name ${STACK_ID}

      check_for_function_exit_code "$?" "Successfully updated CloudFormation stack."

      echo "Building and deploying Lambda image in region ${STACK_REGION}."
        lambda_create_image
        lambda_update_function_image
      ;;
    cf-delete-stack)
      get_account_params
      read -p "Warning: Pressing enter will delete the ECR repository and CloudFormation stack."

      ecr_delete_repo

      aws cloudformation delete-stack \
        --stack-name ${CF_STACK_NAME} >> /dev/null

      echo "Deleting CloudFormation stack. If you want to wait for delete complition please run command below."
      echo "bash ./helper.sh cf-delete-stack-completed"
      ;;
    cf-delete-stack-completed)
      aws cloudformation wait stack-delete-complete \
        --stack-name ${CF_STACK_NAME}

      check_for_function_exit_code "$?" "Successfully deleted CloudFormation stack."
      ;;
    *)
      ;;
esac
