# AWS CDK Examples

Contrast examples demonstrating the four principles applied to AWS CDK infrastructure code (TypeScript/Python). Each shows what LLMs commonly generate vs. what you actually need.

## Table of Contents

1. [Lambda + API Gateway (TypeScript)](#1-cdk-create-a-lambda-function-with-an-api-gateway)
2. [DynamoDB Table (Python)](#2-cdk-create-a-dynamodb-table-for-storing-user-sessions-python)
3. [S3 Upload Processor (TypeScript)](#3-cdk-deploy-a-lambda-that-processes-s3-uploads-typescript)
4. [Step Functions + Bedrock (TypeScript)](#4-cdk-add-a-step-functions-workflow-that-calls-bedrock-typescript)

> **Note:** Model IDs in examples are illustrative. Always use the current model available in your Bedrock console.

---

## 1. CDK: "Create a Lambda function with an API Gateway"

### What LLMs Generate (Overcomplicated)

```typescript
import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as apigw from 'aws-cdk-lib/aws-apigateway';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as iam from 'aws-cdk-lib/aws-iam';

interface ApiLambdaProps {
  functionName?: string;
  memorySize?: number;
  timeout?: cdk.Duration;
  environment?: Record<string, string>;
  logRetention?: logs.RetentionDays;
  reservedConcurrency?: number;
  tracingEnabled?: boolean;
  apiKeyRequired?: boolean;
  throttlingRateLimit?: number;
  throttlingBurstLimit?: number;
}

export class ApiLambdaConstruct extends Construct {
  public readonly function: lambda.Function;
  public readonly api: apigw.RestApi;

  constructor(scope: Construct, id: string, props: ApiLambdaProps = {}) {
    super(scope, id);

    const role = new iam.Role(this, 'LambdaRole', {
      assumedBy: new iam.ServicePrincipal('lambda.amazonaws.com'),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('service-role/AWSLambdaBasicExecutionRole'),
        iam.ManagedPolicy.fromAwsManagedPolicyName('AWSXRayDaemonWriteAccess'),
      ],
    });

    this.function = new lambda.Function(this, 'Handler', {
      runtime: lambda.Runtime.NODEJS_20_X,
      handler: 'index.handler',
      code: lambda.Code.fromAsset('lambda'),
      functionName: props.functionName,
      memorySize: props.memorySize ?? 256,
      timeout: props.timeout ?? cdk.Duration.seconds(30),
      environment: props.environment ?? {},
      logRetention: props.logRetention ?? logs.RetentionDays.ONE_WEEK,
      reservedConcurrentExecutions: props.reservedConcurrency,
      tracing: props.tracingEnabled ? lambda.Tracing.ACTIVE : lambda.Tracing.DISABLED,
      role,
    });

    this.api = new apigw.RestApi(this, 'Api', {
      restApiName: `${props.functionName ?? id}-api`,
      deployOptions: {
        stageName: 'prod',
        tracingEnabled: props.tracingEnabled ?? true,
        metricsEnabled: true,
        loggingLevel: apigw.MethodLoggingLevel.INFO,
        throttlingRateLimit: props.throttlingRateLimit ?? 1000,
        throttlingBurstLimit: props.throttlingBurstLimit ?? 500,
      },
      defaultCorsPreflightOptions: {
        allowOrigins: apigw.Cors.ALL_ORIGINS,
        allowMethods: apigw.Cors.ALL_METHODS,
        allowHeaders: ['Content-Type', 'Authorization'],
      },
    });

    const integration = new apigw.LambdaIntegration(this.function, {
      proxy: true,
      allowTestInvoke: false,
    });

    this.api.root.addMethod('ANY', integration, {
      apiKeyRequired: props.apiKeyRequired ?? false,
    });

    this.api.root.addProxy({
      defaultIntegration: integration,
      anyMethod: true,
    });

    new cdk.CfnOutput(this, 'ApiUrl', {
      value: this.api.url,
    });
  }
}
```

### Problems
- Created a reusable Construct class for a one-off request
- Invented a props interface with 10 optional parameters nobody asked for
- Added X-Ray tracing, CORS, throttling, log retention, reserved concurrency
- Created a custom IAM role when CDK auto-generates one
- Added proxy routes, API key support, metrics
- 70+ lines for what should be ~15

### What You Actually Need

```typescript
import * as cdk from 'aws-cdk-lib';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as apigw from 'aws-cdk-lib/aws-apigateway';

export class MyStack extends cdk.Stack {
  constructor(scope: cdk.App, id: string) {
    super(scope, id);

    const fn = new lambda.Function(this, 'Handler', {
      runtime: lambda.Runtime.NODEJS_20_X,
      handler: 'index.handler',
      code: lambda.Code.fromAsset('lambda'),
    });

    new apigw.LambdaRestApi(this, 'Api', { handler: fn });
  }
}
```

**When to add more:** CORS when you have a frontend. Throttling when you're near production. Custom roles when you need cross-service access. Not before.
---

## 2. CDK: "Create a DynamoDB table for storing user sessions" (Python)

### What LLMs Generate (Overcomplicated)

```python
from aws_cdk import (
    Stack, RemovalPolicy, Duration, CfnOutput,
    aws_dynamodb as dynamodb,
    aws_applicationautoscaling as autoscaling,
    aws_cloudwatch as cloudwatch,
    aws_cloudwatch_actions as cw_actions,
    aws_sns as sns,
)
from constructs import Construct

class SessionTableStack(Stack):
    def __init__(self, scope: Construct, id: str, **kwargs):
        super().__init__(scope, id, **kwargs)

        self.table = dynamodb.Table(
            self, "SessionTable",
            table_name="user-sessions",
            partition_key=dynamodb.Attribute(
                name="userId", type=dynamodb.AttributeType.STRING
            ),
            sort_key=dynamodb.Attribute(
                name="sessionId", type=dynamodb.AttributeType.STRING
            ),
            billing_mode=dynamodb.BillingMode.PROVISIONED,
            read_capacity=10,
            write_capacity=10,
            removal_policy=RemovalPolicy.RETAIN,
            point_in_time_recovery=True,
            encryption=dynamodb.TableEncryption.AWS_MANAGED,
            time_to_live_attribute="ttl",
            stream=dynamodb.StreamViewType.NEW_AND_OLD_IMAGES,
        )

        # GSI for querying sessions by creation time
        self.table.add_global_secondary_index(
            index_name="gsi-created",
            partition_key=dynamodb.Attribute(
                name="userId", type=dynamodb.AttributeType.STRING
            ),
            sort_key=dynamodb.Attribute(
                name="createdAt", type=dynamodb.AttributeType.STRING
            ),
            projection_type=dynamodb.ProjectionType.ALL,
        )

        # Auto-scaling
        read_scaling = self.table.auto_scale_read_capacity(
            min_capacity=5, max_capacity=100
        )
        read_scaling.scale_on_utilization(target_utilization_percent=70)

        write_scaling = self.table.auto_scale_write_capacity(
            min_capacity=5, max_capacity=100
        )
        write_scaling.scale_on_utilization(target_utilization_percent=70)

        # CloudWatch alarm
        alarm_topic = sns.Topic(self, "AlarmTopic")
        throttle_alarm = self.table.metric_throttled_requests_for_operation(
            operation="PutItem",
            period=Duration.minutes(5),
        ).create_alarm(
            self, "ThrottleAlarm",
            threshold=5,
            evaluation_periods=2,
        )
        throttle_alarm.add_alarm_action(cw_actions.SnsAction(alarm_topic))

        CfnOutput(self, "TableName", value=self.table.table_name)
        CfnOutput(self, "TableArn", value=self.table.table_arn)
```

### Problems
- Chose provisioned capacity + auto-scaling when on-demand is simpler for most cases
- Added a GSI with an assumed `createdAt` field that may not exist
- Added DynamoDB Streams (nobody asked for event processing)
- Added CloudWatch alarms and SNS topic
- Assumed `RETAIN` removal policy (might be a dev environment)
- Added point-in-time recovery (costs money, not always needed for sessions)
- Assumed the sort key should be `sessionId` without asking

### What You Actually Need

```python
from aws_cdk import Stack, RemovalPolicy, aws_dynamodb as dynamodb
from constructs import Construct

class SessionTableStack(Stack):
    def __init__(self, scope: Construct, id: str, **kwargs):
        super().__init__(scope, id, **kwargs)

        self.table = dynamodb.Table(
            self, "SessionTable",
            partition_key=dynamodb.Attribute(
                name="sessionId", type=dynamodb.AttributeType.STRING
            ),
            billing_mode=dynamodb.BillingMode.PAY_PER_REQUEST,
            removal_policy=RemovalPolicy.DESTROY,
            time_to_live_attribute="ttl",
        )
```

**Questions the agent should have asked first:**
- What's the access pattern? (partition key design depends on this)
- Do you need a sort key? (not all session stores do)
- Is this a dev or production table? (affects removal policy, backups)
- What throughput do you expect? (on-demand vs. provisioned)
---

## 3. CDK: "Deploy a Lambda that processes S3 uploads" (TypeScript)

### What LLMs Generate (Overcomplicated)

```typescript
import * as cdk from 'aws-cdk-lib';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as s3n from 'aws-cdk-lib/aws-s3-notifications';
import * as sqs from 'aws-cdk-lib/aws-sqs';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as logs from 'aws-cdk-lib/aws-logs';

export class S3ProcessorStack extends cdk.Stack {
  constructor(scope: cdk.App, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    // Dead letter queue for failed processing
    const dlq = new sqs.Queue(this, 'DLQ', {
      retentionPeriod: cdk.Duration.days(14),
    });

    // Main processing queue
    const queue = new sqs.Queue(this, 'ProcessingQueue', {
      visibilityTimeout: cdk.Duration.seconds(300),
      deadLetterQueue: { queue: dlq, maxReceiveCount: 3 },
    });

    const bucket = new s3.Bucket(this, 'UploadBucket', {
      versioned: true,
      encryption: s3.BucketEncryption.S3_MANAGED,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      lifecycleRules: [
        {
          transitions: [
            { storageClass: s3.StorageClass.INFREQUENT_ACCESS, transitionAfter: cdk.Duration.days(30) },
            { storageClass: s3.StorageClass.GLACIER, transitionAfter: cdk.Duration.days(90) },
          ],
        },
      ],
      cors: [{
        allowedMethods: [s3.HttpMethods.PUT, s3.HttpMethods.POST],
        allowedOrigins: ['*'],
        allowedHeaders: ['*'],
      }],
    });

    const processor = new lambda.Function(this, 'Processor', {
      runtime: lambda.Runtime.NODEJS_20_X,
      handler: 'index.handler',
      code: lambda.Code.fromAsset('lambda'),
      timeout: cdk.Duration.minutes(5),
      memorySize: 512,
      retryAttempts: 2,
      deadLetterQueue: dlq,
      logRetention: logs.RetentionDays.TWO_WEEKS,
      environment: {
        BUCKET_NAME: bucket.bucketName,
        QUEUE_URL: queue.queueUrl,
      },
    });

    bucket.grantRead(processor);
    queue.grantSendMessages(processor);

    bucket.addEventNotification(
      s3.EventType.OBJECT_CREATED,
      new s3n.LambdaDestination(processor),
      { prefix: 'uploads/', suffix: '.csv' }
    );
  }
}
```

### Problems
- Added SQS queue + DLQ (user said Lambda processes uploads, not a queue-based pipeline)
- Added lifecycle rules transitioning to Glacier (not requested)
- Added CORS (no mention of browser uploads)
- Added versioning (not requested)
- Assumed CSV files with a prefix filter
- Set memory to 512MB and timeout to 5min without knowing the workload
- Added retry attempts and a second DLQ on the Lambda

### What You Actually Need

```typescript
import * as cdk from 'aws-cdk-lib';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as s3n from 'aws-cdk-lib/aws-s3-notifications';

export class S3ProcessorStack extends cdk.Stack {
  constructor(scope: cdk.App, id: string) {
    super(scope, id);

    const bucket = new s3.Bucket(this, 'UploadBucket');

    const processor = new lambda.Function(this, 'Processor', {
      runtime: lambda.Runtime.NODEJS_20_X,
      handler: 'index.handler',
      code: lambda.Code.fromAsset('lambda'),
    });

    bucket.grantRead(processor);
    bucket.addEventNotification(
      s3.EventType.OBJECT_CREATED,
      new s3n.LambdaDestination(processor),
    );
  }
}
```

**Questions to ask first:**
- What file types/prefixes should trigger processing?
- What does "processes" mean? (transform, copy, notify?)
- Do you need error handling (DLQ) or is this best-effort?
- Existing bucket or new one?
---

## 4. CDK: "Add a Step Functions workflow that calls Bedrock" (TypeScript)

### What LLMs Generate (Overcomplicated)

```typescript
import * as cdk from 'aws-cdk-lib';
import * as sfn from 'aws-cdk-lib/aws-stepfunctions';
import * as tasks from 'aws-cdk-lib/aws-stepfunctions-tasks';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as iam from 'aws-cdk-lib/aws-iam';

export class WorkflowStack extends cdk.Stack {
  constructor(scope: cdk.App, id: string) {
    super(scope, id);

    // Input validation
    const validateInput = new sfn.Choice(this, 'ValidateInput')
      .when(sfn.Condition.isNotPresent('$.prompt'), 
        new sfn.Fail(this, 'MissingPrompt', { error: 'MISSING_PROMPT' }))
      .when(sfn.Condition.stringGreaterThan('$.prompt', ''),
        new sfn.Pass(this, 'InputValid'));

    // Call Bedrock
    const invokeModel = new tasks.BedrockInvokeModel(this, 'InvokeModel', {
      model: tasks.BedrockInvokeModel.CLAUDE_3_SONNET,
      body: sfn.TaskInput.fromObject({
        anthropic_version: 'bedrock-2023-05-31',
        max_tokens: 4096,
        messages: sfn.JsonPath.array(
          sfn.JsonPath.objectAt('$.message')
        ),
      }),
      resultSelector: {
        'response.$': '$.Body.content[0].text',
        'tokens.$': '$.Body.usage',
      },
    });

    // Retry on throttling
    invokeModel.addRetry({
      errors: ['Bedrock.ThrottlingException'],
      interval: cdk.Duration.seconds(2),
      maxAttempts: 5,
      backoffRate: 2,
    });

    // Error handling
    const handleError = new sfn.Pass(this, 'HandleError', {
      result: sfn.Result.fromObject({ error: 'Model invocation failed' }),
    });
    invokeModel.addCatch(handleError, { resultPath: '$.error' });

    // Post-processing choice
    const checkResponse = new sfn.Choice(this, 'CheckResponse')
      .when(sfn.Condition.isPresent('$.response'),
        new sfn.Pass(this, 'Success'))
      .otherwise(handleError);

    // Compose
    const definition = validateInput
      .afterwards()
      .next(invokeModel)
      .next(checkResponse);

    // State machine with logging
    const logGroup = new logs.LogGroup(this, 'SfnLogs', {
      retention: logs.RetentionDays.ONE_WEEK,
    });

    new sfn.StateMachine(this, 'Workflow', {
      definitionBody: sfn.DefinitionBody.fromChainable(definition),
      timeout: cdk.Duration.minutes(5),
      tracingEnabled: true,
      logs: {
        destination: logGroup,
        level: sfn.LogLevel.ALL,
      },
    });
  }
}
```

### Problems
- Added input validation Choice state (user didn't mention validation)
- Added post-processing Choice state
- Added CloudWatch Logs group with retention
- Added X-Ray tracing
- Added complex retry configuration
- Added error handling with catch
- User may just want: trigger -> call model -> done

### What You Actually Need

```typescript
import * as cdk from 'aws-cdk-lib';
import * as sfn from 'aws-cdk-lib/aws-stepfunctions';
import * as tasks from 'aws-cdk-lib/aws-stepfunctions-tasks';

export class WorkflowStack extends cdk.Stack {
  constructor(scope: cdk.App, id: string) {
    super(scope, id);

    const invokeModel = new tasks.BedrockInvokeModel(this, 'InvokeModel', {
      model: tasks.BedrockInvokeModel.CLAUDE_3_SONNET,
      body: sfn.TaskInput.fromObject({
        anthropic_version: 'bedrock-2023-05-31',
        max_tokens: 1024,
        messages: sfn.JsonPath.array(sfn.JsonPath.objectAt('$.message')),
      }),
      resultSelector: { 'response.$': '$.Body.content[0].text' },
    });

    new sfn.StateMachine(this, 'Workflow', {
      definitionBody: sfn.DefinitionBody.fromChainable(invokeModel),
    });
  }
}
```

**Add when needed:** Retry config when you're hitting throttling. Error handling when you need graceful degradation. Logging when you're debugging in production.

---

## Anti-Patterns Summary (CDK)

| Scenario | LLM Over-Engineering | What's Actually Needed |
|----------|---------------------|----------------------|
| Lambda + APIGW | Custom construct, props interface, X-Ray, CORS, throttling | `LambdaRestApi` one-liner |
| DynamoDB table | Provisioned + autoscaling + GSI + streams + alarms | On-demand + partition key + TTL |
| S3 processor | SQS + DLQ + lifecycle rules + CORS + versioning | Bucket + Lambda + notification |
| Step Functions | Input validation + error handling + logging + tracing | One task, one state machine |

---

## Key Insight

CDK's L2 constructs already encapsulate best practices. LLMs tend to:
1. **Recreate what CDK gives you for free** (IAM roles, log groups, permissions)
2. **Add production hardening to POC code** (autoscaling, alarms, DLQs)
3. **Build class hierarchies for single-use infrastructure**

The rule: **Start with the highest-level construct. Drop to L1 only when L2 can't express what you need.** Ask whether it's a POC or production before adding operational overhead.
