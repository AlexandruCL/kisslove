# AWS Multi-Service Compositions: Handling Legitimate Complexity

## Preamble

**This file is different from the other reference files in this skill.**

The other references teach agents not to overcomplicate simple things - don't add caching to a CRUD API, don't introduce event sourcing for a todo app, don't reach for microservices when a monolith works.

**This file teaches the opposite discipline**: when the user's requirements genuinely demand multi-service orchestration, how to implement it correctly without:
- Stripping out pieces that are actually required (under-engineering)
- Adding speculative pieces that aren't required yet (over-engineering)
- Wiring services together incorrectly (mis-engineering)

The complexity in these patterns is **intrinsic** - it comes from the problem domain, not from the agent's desire to be impressive. A RAG pipeline genuinely needs embedding, indexing, chunking, and retrieval. A document processing pipeline genuinely needs error handling, retries, and state management. The agent's job is to implement these correctly, not to simplify them away.

> **Note on model IDs**: Model identifiers like `amazon.titan-embed-text-v2:0` and `anthropic.claude-3-sonnet-20240229-v1:0` are illustrative. Always verify current model IDs in AWS documentation, as they change with new releases. The patterns and wiring remain the same regardless of specific model version.

---

## Table of Contents

1. [Pattern 1: RAG Pipeline with Vector Store](#pattern-1-rag-pipeline-with-vector-store)
2. [Pattern 2: Multi-Hop Retrieval Orchestration](#pattern-2-multi-hop-retrieval-orchestration)
3. [Pattern 3: Event-Driven Document Processing Pipeline](#pattern-3-event-driven-document-processing-pipeline)
4. [Pattern 4: API Composition with Bedrock Agents](#pattern-4-api-composition-with-bedrock-agents)
5. [Pattern 5: Real-Time Streaming with Guardrails](#pattern-5-real-time-streaming-with-guardrails)

---

## Pattern 1: RAG Pipeline with Vector Store

### The Prompt

> "Build a RAG pipeline that ingests documents from S3, chunks them, generates embeddings with Titan, stores them in OpenSearch Serverless with a neural search pipeline, and tracks document metadata in DynamoDB. I need a query API that does semantic search."

### What the Agent Should Clarify First

1. **Scale & query pattern**: How many documents? How frequently ingested? Query latency requirements?
   - < 10k documents, simple Q&A → **Bedrock Knowledge Bases** (managed, less code)
   - 10k-1M documents, custom chunking/ranking needed → **OpenSearch Serverless** (this pattern)
   - Need SQL-style filtering + vector search → **Aurora pgvector**

2. **Chunking strategy**: Fixed-size with overlap? Semantic boundaries? Per-paragraph?
   - This determines Lambda memory/timeout requirements

3. **Access patterns**: Public API? Internal service? Multi-tenant?
   - Determines whether you need a network policy of type `Public` or `VPC`

4. **Embedding model**: Titan Embed V2 (1024 dims) vs. Cohere (1024 dims) vs. custom?
   - Determines index mapping dimensions and ML connector config

### The Correct CDK Implementation

```typescript
import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as opensearchserverless from 'aws-cdk-lib/aws-opensearchserverless';
import * as s3n from 'aws-cdk-lib/aws-s3-notifications';
import * as sqs from 'aws-cdk-lib/aws-sqs';
import * as lambdaEventSources from 'aws-cdk-lib/aws-lambda-event-sources';

export class RagPipelineStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    const collectionName = 'rag-vectors';

    // --- OpenSearch Serverless: Three required policies ---
    // These are NOT optional. AOSS won't work without all three.

    // 1. Encryption policy (required BEFORE collection creation)
    const encryptionPolicy = new opensearchserverless.CfnSecurityPolicy(this, 'EncryptionPolicy', {
      name: `${collectionName}-enc`,
      type: 'encryption',
      policy: JSON.stringify({
        Rules: [{ ResourceType: 'collection', Resource: [`collection/${collectionName}`] }],
        AWSOwnedKey: true,
      }),
    });

    // 2. Network policy (required - controls access path)
    const networkPolicy = new opensearchserverless.CfnSecurityPolicy(this, 'NetworkPolicy', {
      name: `${collectionName}-net`,
      type: 'network',
      policy: JSON.stringify([{
        Rules: [
          { ResourceType: 'collection', Resource: [`collection/${collectionName}`] },
          { ResourceType: 'dashboard', Resource: [`collection/${collectionName}`] },
        ],
        AllowFromPublic: true, // Change to VPC endpoint for production
      }]),
    });

    // 3. Data access policy (required - without this, NO principal can read/write indexes)
    const dataAccessPolicy = new opensearchserverless.CfnAccessPolicy(this, 'DataAccessPolicy', {
      name: `${collectionName}-access`,
      type: 'data',
      policy: JSON.stringify([{
        Rules: [
          {
            ResourceType: 'index',
            Resource: [`index/${collectionName}/*`],
            Permission: [
              'aoss:CreateIndex',
              'aoss:UpdateIndex',
              'aoss:DescribeIndex',
              'aoss:ReadDocument',
              'aoss:WriteDocument',
            ],
          },
          {
            ResourceType: 'collection',
            Resource: [`collection/${collectionName}`],
            Permission: [
              'aoss:CreateCollectionItems',
              'aoss:DescribeCollectionItems',
              'aoss:UpdateCollectionItems',
            ],
          },
        ],
        // Principal will be updated after Lambda roles are created
        Principal: [] as string[], // Populated below
      }]),
    });

    // Collection (depends on encryption policy existing first)
    const collection = new opensearchserverless.CfnCollection(this, 'VectorCollection', {
      name: collectionName,
      type: 'VECTORSEARCH', // Critical: must be VECTORSEARCH for knn
    });
    collection.addDependency(encryptionPolicy);
    collection.addDependency(networkPolicy);

    // --- DynamoDB for document metadata ---
    const metadataTable = new dynamodb.Table(this, 'DocumentMetadata', {
      partitionKey: { name: 'documentId', type: dynamodb.AttributeType.STRING },
      sortKey: { name: 'chunkId', type: dynamodb.AttributeType.STRING },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });

    // GSI for querying by source document
    metadataTable.addGlobalSecondaryIndex({
      indexName: 'by-source',
      partitionKey: { name: 'sourceKey', type: dynamodb.AttributeType.STRING },
      sortKey: { name: 'createdAt', type: dynamodb.AttributeType.STRING },
    });

    // --- S3 bucket for document ingestion ---
    const ingestBucket = new s3.Bucket(this, 'IngestBucket', {
      eventBridgeEnabled: true, // Prefer EventBridge over S3 notifications for filtering
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });

    // --- Dead letter queue for failed processing ---
    const dlq = new sqs.Queue(this, 'IngestDLQ', {
      retentionPeriod: cdk.Duration.days(14),
    });

    const ingestQueue = new sqs.Queue(this, 'IngestQueue', {
      visibilityTimeout: cdk.Duration.minutes(15), // Must exceed Lambda timeout
      deadLetterQueue: { queue: dlq, maxReceiveCount: 3 },
    });

    // --- Ingestion Lambda (chunking + embedding + indexing) ---
    const ingestFn = new lambda.Function(this, 'IngestFunction', {
      runtime: lambda.Runtime.PYTHON_3_12,
      handler: 'index.handler',
      code: lambda.Code.fromAsset('lambda/ingest'),
      timeout: cdk.Duration.minutes(10), // Large documents need time
      memorySize: 1024, // Chunking is memory-intensive
      environment: {
        COLLECTION_ENDPOINT: collection.attrCollectionEndpoint,
        INDEX_NAME: 'documents',
        METADATA_TABLE: metadataTable.tableName,
        EMBEDDING_MODEL_ID: 'amazon.titan-embed-text-v2:0',
      },
      reservedConcurrentExecutions: 10, // Prevent overwhelming OpenSearch
    });

    // SQS trigger
    ingestFn.addEventSource(new lambdaEventSources.SqsEventSource(ingestQueue, {
      batchSize: 1, // Process one document at a time (they're large)
      maxConcurrency: 10,
    }));

    // S3 → SQS notification (filtered to relevant prefixes)
    ingestBucket.addObjectCreatedNotification(new s3n.SqsDestination(ingestQueue), {
      prefix: 'documents/',
      suffix: '.pdf',
    });
    ingestBucket.addObjectCreatedNotification(new s3n.SqsDestination(ingestQueue), {
      prefix: 'documents/',
      suffix: '.txt',
    });

    // --- Query Lambda ---
    const queryFn = new lambda.Function(this, 'QueryFunction', {
      runtime: lambda.Runtime.PYTHON_3_12,
      handler: 'index.handler',
      code: lambda.Code.fromAsset('lambda/query'),
      timeout: cdk.Duration.seconds(30),
      memorySize: 256,
      environment: {
        COLLECTION_ENDPOINT: collection.attrCollectionEndpoint,
        INDEX_NAME: 'documents',
        METADATA_TABLE: metadataTable.tableName,
        EMBEDDING_MODEL_ID: 'amazon.titan-embed-text-v2:0',
      },
    });

    // --- IAM: Precise permissions ---
    // Bedrock invoke (for embeddings)
    const bedrockEmbedPolicy = new iam.PolicyStatement({
      actions: ['bedrock:InvokeModel'],
      resources: [
        `arn:aws:bedrock:${this.region}::foundation-model/amazon.titan-embed-text-v2:0`,
      ],
    });
    ingestFn.addToRolePolicy(bedrockEmbedPolicy);
    queryFn.addToRolePolicy(bedrockEmbedPolicy);

    // AOSS API access (the data access policy grants index-level; this grants API-level)
    const aossApiPolicy = new iam.PolicyStatement({
      actions: ['aoss:APIAccessAll'],
      resources: [collection.attrArn],
    });
    ingestFn.addToRolePolicy(aossApiPolicy);
    queryFn.addToRolePolicy(aossApiPolicy);

    // S3 read for ingest
    ingestBucket.grantRead(ingestFn);

    // DynamoDB access
    metadataTable.grantWriteData(ingestFn);
    metadataTable.grantReadData(queryFn);

    // --- Update data access policy with actual role ARNs ---
    // This is the piece agents most commonly forget
    const actualDataAccessPolicy = new opensearchserverless.CfnAccessPolicy(this, 'ActualDataAccessPolicy', {
      name: `${collectionName}-access`,
      type: 'data',
      policy: JSON.stringify([{
        Rules: [
          {
            ResourceType: 'index',
            Resource: [`index/${collectionName}/*`],
            Permission: [
              'aoss:CreateIndex', 'aoss:UpdateIndex', 'aoss:DescribeIndex',
              'aoss:ReadDocument', 'aoss:WriteDocument',
            ],
          },
          {
            ResourceType: 'collection',
            Resource: [`collection/${collectionName}`],
            Permission: ['aoss:CreateCollectionItems', 'aoss:DescribeCollectionItems', 'aoss:UpdateCollectionItems'],
          },
        ],
        Principal: [
          ingestFn.role!.roleArn,
          queryFn.role!.roleArn,
        ],
      }]),
    });
    // Remove the placeholder policy
    // In practice, use a single policy with Lazy.string for the principal ARNs

    // --- Outputs ---
    new cdk.CfnOutput(this, 'CollectionEndpoint', { value: collection.attrCollectionEndpoint });
    new cdk.CfnOutput(this, 'IngestBucketName', { value: ingestBucket.bucketName });
  }
}
```

**Runtime: Ingest Lambda (Python)**

```python
# lambda/ingest/index.py
import json
import os
import boto3
from opensearchpy import OpenSearch, RequestsHttpConnection, AWSV4SignerAuth

bedrock = boto3.client('bedrock-runtime')
dynamodb = boto3.resource('dynamodb')
s3 = boto3.client('s3')

table = dynamodb.Table(os.environ['METADATA_TABLE'])
collection_endpoint = os.environ['COLLECTION_ENDPOINT']
index_name = os.environ['INDEX_NAME']
model_id = os.environ['EMBEDDING_MODEL_ID']

# AOSS client with SigV4
credentials = boto3.Session().get_credentials()
auth = AWSV4SignerAuth(credentials, os.environ['AWS_REGION'], 'aoss')
client = OpenSearch(
    hosts=[{'host': collection_endpoint.replace('https://', ''), 'port': 443}],
    http_auth=auth,
    use_ssl=True,
    verify_certs=True,
    connection_class=RequestsHttpConnection,
)


def get_embedding(text: str) -> list[float]:
    """Get embedding from Titan V2."""
    response = bedrock.invoke_model(
        modelId=model_id,
        body=json.dumps({'inputText': text, 'dimensions': 1024, 'normalize': True}),
    )
    return json.loads(response['body'].read())['embedding']


def chunk_text(text: str, chunk_size: int = 512, overlap: int = 50) -> list[str]:
    """Simple fixed-size chunking with overlap. Replace with semantic chunking as needed."""
    words = text.split()
    chunks = []
    for i in range(0, len(words), chunk_size - overlap):
        chunk = ' '.join(words[i:i + chunk_size])
        if chunk:
            chunks.append(chunk)
    return chunks


def handler(event, context):
    for record in event['Records']:
        body = json.loads(record['body'])
        bucket = body['Records'][0]['s3']['bucket']['name']
        key = body['Records'][0]['s3']['object']['key']

        # Download and extract text (simplified - use textract for PDFs in production)
        obj = s3.get_object(Bucket=bucket, Key=key)
        text = obj['Body'].read().decode('utf-8')

        chunks = chunk_text(text)
        doc_id = key.replace('/', '_')

        for i, chunk in enumerate(chunks):
            chunk_id = f"{doc_id}_chunk_{i}"
            embedding = get_embedding(chunk)

            # Index in OpenSearch
            client.index(
                index=index_name,
                id=chunk_id,
                body={
                    'text': chunk,
                    'embedding': embedding,
                    'source_key': key,
                    'chunk_index': i,
                },
            )

            # Track metadata in DynamoDB
            table.put_item(Item={
                'documentId': doc_id,
                'chunkId': chunk_id,
                'sourceKey': key,
                'chunkIndex': i,
                'charCount': len(chunk),
                'createdAt': context.invoked_function_arn,  # Use proper timestamp
            })

    return {'statusCode': 200}
```

**Index mapping (must be created before first ingest):**

```json
{
  "settings": {
    "index": {
      "knn": true,
      "knn.algo_param.ef_search": 512
    }
  },
  "mappings": {
    "properties": {
      "embedding": {
        "type": "knn_vector",
        "dimension": 1024,
        "method": {
          "engine": "faiss",
          "name": "hnsw",
          "space_type": "l2",
          "parameters": { "ef_construction": 512, "m": 16 }
        }
      },
      "text": { "type": "text" },
      "source_key": { "type": "keyword" },
      "chunk_index": { "type": "integer" }
    }
  }
}
```

### What's Optional vs. Required

| Component | Required? | Why |
|-----------|-----------|-----|
| Encryption policy | **Required** | AOSS won't create collection without it |
| Network policy | **Required** | AOSS won't allow any access without it |
| Data access policy | **Required** | No principal can touch indexes without it |
| DLQ on ingest queue | **Required** | Documents will silently disappear on failure without it |
| SQS between S3 and Lambda | **Required** | Direct S3→Lambda has no retry; large docs timeout |
| DynamoDB metadata table | Depends | Required if you need to track lineage, delete by source, or filter results |
| Reserved concurrency on ingest | Recommended | Prevents overwhelming AOSS during bulk ingest |
| Neural ingest pipeline (AOSS-side) | Optional | Client-side embedding (this pattern) is simpler; neural pipeline is for when you want AOSS to call Bedrock directly |
| VPC endpoint for AOSS | Optional | Only if network policy requires VPC access |
| Custom KMS key for encryption | Optional | AWS-owned key is fine unless compliance requires CMK |

### Common Agent Mistakes at This Complexity Level

1. **Forgetting the data access policy entirely** - The collection creates fine, but all index operations return 403. Agents see the encryption and network policies and assume that's sufficient.

2. **Wrong collection type** - Using `SEARCH` instead of `VECTORSEARCH`. The collection creates but `knn_vector` field type is rejected.

3. **Mismatched embedding dimensions** - Titan V2 defaults to 1024 but supports 256/512/1024. If the index mapping says 1024 but the embedding call doesn't specify `dimensions: 1024`, you get dimension mismatch errors.

4. **Missing `aoss:APIAccessAll` IAM permission** - The data access policy grants index-level permissions, but the Lambda role also needs the IAM permission to call the AOSS API endpoint. These are two separate auth layers.

5. **SQS visibility timeout < Lambda timeout** - If Lambda takes 10 minutes but SQS visibility is 30 seconds, the message becomes visible again and triggers duplicate processing.

6. **Direct S3→Lambda without SQS** - S3 notifications to Lambda have no built-in retry. If the Lambda fails, the document is lost. Always buffer through SQS for document processing.

---

## Pattern 2: Multi-Hop Retrieval Orchestration

### The Prompt

> "Build a query API that decomposes complex questions into sub-queries, retrieves from multiple knowledge stores in parallel, then synthesizes a final answer using Claude. It needs Cognito auth and should handle multi-turn conversations."

### What the Agent Should Clarify First

1. **Query complexity**: Are sub-queries truly independent (parallel retrieval) or do later queries depend on earlier results (sequential)?
   - Independent → Step Functions Parallel state
   - Dependent → Step Functions sequential with result passing

2. **Number of knowledge stores**: How many and what types?
   - 2-3 stores, simple fan-out → Could be a single Lambda with `Promise.all`
   - 4+ stores, different retry/timeout needs, or need visibility into which step failed → Step Functions

3. **Latency budget**: How long can the user wait?
   - < 3 seconds → Single Lambda with parallel calls (avoid Step Functions overhead ~200ms)
   - 3-30 seconds → Step Functions Express (synchronous)
   - > 30 seconds → Step Functions Standard (async with callback)

4. **Conversation state**: Where does multi-turn context live?
   - DynamoDB session table (simple, works)
   - Client-side (stateless API, client sends history)

### The Correct CDK Implementation

```typescript
import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import * as apigateway from 'aws-cdk-lib/aws-apigateway';
import * as cognito from 'aws-cdk-lib/aws-cognito';
import * as stepfunctions from 'aws-cdk-lib/aws-stepfunctions';
import * as tasks from 'aws-cdk-lib/aws-stepfunctions-tasks';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as logs from 'aws-cdk-lib/aws-logs';

export class MultiHopRetrievalStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    // --- Cognito User Pool ---
    const userPool = new cognito.UserPool(this, 'QueryUserPool', {
      selfSignUpEnabled: false,
      signInAliases: { email: true },
      passwordPolicy: {
        minLength: 12,
        requireUppercase: true,
        requireDigits: true,
        requireSymbols: true,
      },
    });

    const userPoolClient = new cognito.UserPoolClient(this, 'QueryClient', {
      userPool,
      authFlows: { userSrp: true },
      generateSecret: false,
    });

    // --- Session table for multi-turn ---
    const sessionTable = new dynamodb.Table(this, 'SessionTable', {
      partitionKey: { name: 'sessionId', type: dynamodb.AttributeType.STRING },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      timeToLiveAttribute: 'ttl', // Auto-expire old sessions
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    // --- Lambda functions for each retrieval source ---
    const commonLambdaProps: Partial<lambda.FunctionProps> = {
      runtime: lambda.Runtime.PYTHON_3_12,
      timeout: cdk.Duration.seconds(30),
      memorySize: 512,
    };

    const decomposeFn = new lambda.Function(this, 'DecomposeQuery', {
      ...commonLambdaProps,
      handler: 'decompose.handler',
      code: lambda.Code.fromAsset('lambda/decompose'),
      environment: {
        MODEL_ID: 'anthropic.claude-3-haiku-20240307-v1:0', // Fast model for decomposition
      },
    });

    const retrieveVectorFn = new lambda.Function(this, 'RetrieveVector', {
      ...commonLambdaProps,
      handler: 'retrieve_vector.handler',
      code: lambda.Code.fromAsset('lambda/retrieve-vector'),
      environment: {
        COLLECTION_ENDPOINT: 'REPLACE_WITH_AOSS_ENDPOINT',
        INDEX_NAME: 'documents',
        EMBEDDING_MODEL_ID: 'amazon.titan-embed-text-v2:0',
      },
    });

    const retrieveStructuredFn = new lambda.Function(this, 'RetrieveStructured', {
      ...commonLambdaProps,
      handler: 'retrieve_structured.handler',
      code: lambda.Code.fromAsset('lambda/retrieve-structured'),
      environment: {
        // e.g., Aurora or DynamoDB connection info
      },
    });

    const synthesizeFn = new lambda.Function(this, 'Synthesize', {
      ...commonLambdaProps,
      handler: 'synthesize.handler',
      code: lambda.Code.fromAsset('lambda/synthesize'),
      timeout: cdk.Duration.seconds(60), // Synthesis with Claude can take longer
      memorySize: 1024,
      environment: {
        MODEL_ID: 'anthropic.claude-3-sonnet-20240229-v1:0',
        SESSION_TABLE: sessionTable.tableName,
      },
    });

    // --- IAM: Bedrock access (scoped to specific models) ---
    decomposeFn.addToRolePolicy(new iam.PolicyStatement({
      actions: ['bedrock:InvokeModel'],
      resources: [`arn:aws:bedrock:${this.region}::foundation-model/anthropic.claude-3-haiku-20240307-v1:0`],
    }));

    synthesizeFn.addToRolePolicy(new iam.PolicyStatement({
      actions: ['bedrock:InvokeModel'],
      resources: [`arn:aws:bedrock:${this.region}::foundation-model/anthropic.claude-3-sonnet-20240229-v1:0`],
    }));

    retrieveVectorFn.addToRolePolicy(new iam.PolicyStatement({
      actions: ['bedrock:InvokeModel'],
      resources: [`arn:aws:bedrock:${this.region}::foundation-model/amazon.titan-embed-text-v2:0`],
    }));

    retrieveVectorFn.addToRolePolicy(new iam.PolicyStatement({
      actions: ['aoss:APIAccessAll'],
      resources: ['*'], // Scope to collection ARN in production
    }));

    sessionTable.grantReadWriteData(synthesizeFn);

    // --- Step Functions: Express workflow (synchronous, <5 min) ---

    // Step 1: Decompose the query
    const decomposeTask = new tasks.LambdaInvoke(this, 'DecomposeTask', {
      lambdaFunction: decomposeFn,
      // IMPORTANT: Use .resultSelector to shape output, not .outputPath alone
      resultSelector: {
        'subQueries.$': '$.Payload.subQueries',
        'originalQuery.$': '$.Payload.originalQuery',
      },
      resultPath: '$.decomposition',
    });

    // Step 2: Parallel retrieval from multiple stores
    const parallelRetrieval = new stepfunctions.Parallel(this, 'ParallelRetrieval', {
      resultPath: '$.retrievalResults',
    });

    // Branch 1: Vector search (run for each sub-query via Map)
    const vectorSearchMap = new stepfunctions.Map(this, 'VectorSearchMap', {
      itemsPath: '$.decomposition.subQueries',
      maxConcurrency: 5,
      resultPath: '$.vectorResults',
    });
    vectorSearchMap.itemProcessor(
      new tasks.LambdaInvoke(this, 'VectorSearchTask', {
        lambdaFunction: retrieveVectorFn,
        resultSelector: { 'results.$': '$.Payload.results' },
      })
    );

    // Branch 2: Structured data retrieval
    const structuredTask = new tasks.LambdaInvoke(this, 'StructuredSearchTask', {
      lambdaFunction: retrieveStructuredFn,
      resultSelector: { 'results.$': '$.Payload.results' },
    });

    parallelRetrieval.branch(vectorSearchMap);
    parallelRetrieval.branch(structuredTask);

    // Step 3: Synthesize final answer
    const synthesizeTask = new tasks.LambdaInvoke(this, 'SynthesizeTask', {
      lambdaFunction: synthesizeFn,
      resultSelector: {
        'answer.$': '$.Payload.answer',
        'sources.$': '$.Payload.sources',
        'sessionId.$': '$.Payload.sessionId',
      },
    });

    // Chain the workflow
    const definition = decomposeTask
      .next(parallelRetrieval)
      .next(synthesizeTask);

    // Express workflow for synchronous execution
    const stateMachine = new stepfunctions.StateMachine(this, 'QueryOrchestrator', {
      definitionBody: stepfunctions.DefinitionBody.fromChainable(definition),
      stateMachineType: stepfunctions.StateMachineType.EXPRESS,
      timeout: cdk.Duration.minutes(2),
      logs: {
        destination: new logs.LogGroup(this, 'StateMachineLogs', {
          retention: logs.RetentionDays.ONE_WEEK,
        }),
        level: stepfunctions.LogLevel.ERROR,
      },
      tracingEnabled: true,
    });

    // --- API Gateway with Cognito authorizer ---
    const api = new apigateway.RestApi(this, 'QueryApi', {
      restApiName: 'Multi-Hop Query API',
      deployOptions: { stageName: 'v1' },
    });

    const authorizer = new apigateway.CognitoUserPoolsAuthorizer(this, 'CognitoAuth', {
      cognitoUserPools: [userPool],
    });

    // Integration: API GW → Step Functions (synchronous start)
    const sfnIntegrationRole = new iam.Role(this, 'ApiSfnRole', {
      assumedBy: new iam.ServicePrincipal('apigateway.amazonaws.com'),
    });
    stateMachine.grantStartSyncExecution(sfnIntegrationRole);

    const queryResource = api.root.addResource('query');
    queryResource.addMethod('POST',
      new apigateway.AwsIntegration({
        service: 'states',
        action: 'StartSyncExecution',
        integrationHttpMethod: 'POST',
        options: {
          credentialsRole: sfnIntegrationRole,
          requestTemplates: {
            'application/json': JSON.stringify({
              stateMachineArn: stateMachine.stateMachineArn,
              input: "$util.escapeJavaScript($input.body)",
            }),
          },
          integrationResponses: [{
            statusCode: '200',
            responseTemplates: {
              'application/json': `
                #set($output = $util.parseJson($input.body))
                #if($output.status == "SUCCEEDED")
                  $output.output
                #else
                  {"error": "Query processing failed", "cause": "$output.error"}
                #end
              `,
            },
          }],
        },
      }),
      {
        authorizer,
        authorizationType: apigateway.AuthorizationType.COGNITO,
        methodResponses: [{ statusCode: '200' }],
      },
    );

    // --- Outputs ---
    new cdk.CfnOutput(this, 'ApiEndpoint', { value: api.url });
    new cdk.CfnOutput(this, 'UserPoolId', { value: userPool.userPoolId });
    new cdk.CfnOutput(this, 'UserPoolClientId', { value: userPoolClient.userPoolClientId });
  }
}
```

### What's Optional vs. Required

| Component | Required? | Why |
|-----------|-----------|-----|
| Cognito authorizer | **Required** (per prompt) | User specified auth; without it, API is public |
| Step Functions (vs. single Lambda) | Depends on latency | If < 3s latency needed and only 2-3 sources, single Lambda with parallel calls is simpler |
| Express workflow (vs. Standard) | **Required for sync API** | Standard workflows are async-only; Express supports StartSyncExecution |
| Session table TTL | Recommended | Prevents unbounded storage growth |
| Parallel state in Step Functions | **Required** | The whole point is parallel retrieval |
| Map state for sub-queries | Required if decomposition produces variable-length output | Otherwise a fixed Parallel with known branches works |
| X-Ray tracing | Optional but valuable | Helps debug latency in multi-hop flows |
| Request validation on API GW | Recommended | Catch malformed requests before they hit Step Functions |
| API Gateway response mapping template | **Required** | Step Functions returns execution metadata; you need to extract just the output |

### Common Agent Mistakes at This Complexity Level

1. **Using Standard workflow with StartSyncExecution** - Standard workflows don't support `StartSyncExecution`. Only Express workflows do. The API call will fail with a validation error.

2. **Over-permissive IAM with `bedrock:InvokeModel` on `*`** - Each Lambda only needs access to its specific model. An agent that grants `Resource: '*'` gives every function access to every model.

3. **Wrong Step Functions integration pattern** - Using `.resultPath('$')` overwrites the entire state. Use `.resultPath('$.stepOutput')` to merge results into existing state. This is the #1 debugging nightmare in Step Functions.

4. **Missing Cognito authorizer on the method** - Defining the authorizer construct but forgetting to attach it to the method via `authorizer` and `authorizationType` options. The API deploys fine but has no auth.

5. **API Gateway → Step Functions without response mapping** - The raw StartSyncExecution response includes execution ARN, status, timestamps, etc. Without a response template, clients get Step Functions metadata instead of the actual answer.

6. **Parallel state error handling** - If one branch fails, the entire Parallel state fails by default. Use `addCatch` on the Parallel state to handle partial failures gracefully.

---

## Pattern 3: Event-Driven Document Processing Pipeline

### The Prompt

> "Build a pipeline that automatically processes documents uploaded to S3 - detect document type, extract text, chunk it, generate embeddings, store in a vector database and track status in DynamoDB. It needs to handle failures gracefully and not reprocess documents."

### What the Agent Should Clarify First

1. **Document types**: PDF only? Office docs? Images (OCR needed)?
   - PDF/text → Lambda with PyPDF2 or Textract
   - Images/complex PDFs → Amazon Textract (async API, needs callback pattern)
   - This changes the architecture significantly (Textract is async with SNS callback)

2. **Document sizes**: What's the max document size?
   - < 6MB → Lambda can process synchronously
   - 6MB-500MB → Need chunked processing, possibly ECS/Fargate
   - This determines Lambda timeout and memory

3. **Event source preference**:
   - EventBridge: Best for filtering, routing to multiple targets, archival
   - S3 notifications → SQS: Simpler, fewer moving parts, good enough for single consumer
   - S3 notifications → Lambda: No retry, only for idempotent fire-and-forget

4. **Idempotency requirement**: How to handle duplicate S3 events?
   - DynamoDB conditional write (check-then-process)
   - S3 event deduplication via event ID

### The Correct CDK Implementation

```typescript
import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as stepfunctions from 'aws-cdk-lib/aws-stepfunctions';
import * as tasks from 'aws-cdk-lib/aws-stepfunctions-tasks';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import * as events from 'aws-cdk-lib/aws-events';
import * as targets from 'aws-cdk-lib/aws-events-targets';
import * as sqs from 'aws-cdk-lib/aws-sqs';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as logs from 'aws-cdk-lib/aws-logs';

export class DocumentProcessingStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    // --- S3 bucket with EventBridge enabled ---
    const docBucket = new s3.Bucket(this, 'DocumentBucket', {
      eventBridgeEnabled: true, // REQUIRED for EventBridge rules to fire
      removalPolicy: cdk.RemovalPolicy.RETAIN,
      versioning: true, // Helps with idempotency checks
    });

    // --- Status tracking table ---
    const statusTable = new dynamodb.Table(this, 'ProcessingStatus', {
      partitionKey: { name: 'documentKey', type: dynamodb.AttributeType.STRING },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });

    // --- DLQ for the entire pipeline ---
    const pipelineDlq = new sqs.Queue(this, 'PipelineDLQ', {
      retentionPeriod: cdk.Duration.days(14),
    });

    // --- Processing Lambdas ---
    const detectTypeFn = new lambda.Function(this, 'DetectType', {
      runtime: lambda.Runtime.PYTHON_3_12,
      handler: 'detect_type.handler',
      code: lambda.Code.fromAsset('lambda/detect-type'),
      timeout: cdk.Duration.seconds(30),
      memorySize: 256,
    });

    const extractTextFn = new lambda.Function(this, 'ExtractText', {
      runtime: lambda.Runtime.PYTHON_3_12,
      handler: 'extract_text.handler',
      code: lambda.Code.fromAsset('lambda/extract-text'),
      timeout: cdk.Duration.minutes(5), // PDF extraction can be slow
      memorySize: 2048, // PyPDF2/pdfplumber need memory
    });

    const chunkFn = new lambda.Function(this, 'ChunkText', {
      runtime: lambda.Runtime.PYTHON_3_12,
      handler: 'chunk.handler',
      code: lambda.Code.fromAsset('lambda/chunk'),
      timeout: cdk.Duration.minutes(2),
      memorySize: 1024,
    });

    const embedFn = new lambda.Function(this, 'GenerateEmbeddings', {
      runtime: lambda.Runtime.PYTHON_3_12,
      handler: 'embed.handler',
      code: lambda.Code.fromAsset('lambda/embed'),
      timeout: cdk.Duration.minutes(5),
      memorySize: 512,
      environment: {
        EMBEDDING_MODEL_ID: 'amazon.titan-embed-text-v2:0',
      },
    });

    const storeFn = new lambda.Function(this, 'StoreVectors', {
      runtime: lambda.Runtime.PYTHON_3_12,
      handler: 'store.handler',
      code: lambda.Code.fromAsset('lambda/store'),
      timeout: cdk.Duration.minutes(3),
      memorySize: 512,
      environment: {
        STATUS_TABLE: statusTable.tableName,
        COLLECTION_ENDPOINT: 'REPLACE_WITH_AOSS_ENDPOINT',
      },
    });

    // --- IAM ---
    docBucket.grantRead(detectTypeFn);
    docBucket.grantRead(extractTextFn);
    statusTable.grantReadWriteData(storeFn);
    statusTable.grantReadData(detectTypeFn); // For idempotency check

    embedFn.addToRolePolicy(new iam.PolicyStatement({
      actions: ['bedrock:InvokeModel'],
      resources: [`arn:aws:bedrock:${this.region}::foundation-model/amazon.titan-embed-text-v2:0`],
    }));

    storeFn.addToRolePolicy(new iam.PolicyStatement({
      actions: ['aoss:APIAccessAll'],
      resources: ['*'], // Scope to collection ARN
    }));

    // --- Step Functions workflow ---

    // Idempotency check: skip if already processed
    const checkIdempotency = new tasks.DynamoGetItem(this, 'CheckAlreadyProcessed', {
      table: statusTable,
      key: { documentKey: tasks.DynamoAttributeValue.fromString(stepfunctions.JsonPath.stringAt('$.detail.object.key')) },
      resultPath: '$.existingRecord',
    });

    const alreadyProcessed = new stepfunctions.Choice(this, 'AlreadyProcessed?')
      .when(
        stepfunctions.Condition.isPresent('$.existingRecord.Item.status'),
        new stepfunctions.Succeed(this, 'SkipDuplicate', { comment: 'Document already processed' })
      );

    // Mark as processing
    const markProcessing = new tasks.DynamoPutItem(this, 'MarkProcessing', {
      table: statusTable,
      item: {
        documentKey: tasks.DynamoAttributeValue.fromString(stepfunctions.JsonPath.stringAt('$.detail.object.key')),
        status: tasks.DynamoAttributeValue.fromString('PROCESSING'),
        startedAt: tasks.DynamoAttributeValue.fromString(stepfunctions.JsonPath.stringAt('$$.State.EnteredTime')),
      },
      resultPath: stepfunctions.JsonPath.DISCARD,
    });

    // Processing steps
    const detectTask = new tasks.LambdaInvoke(this, 'DetectTypeTask', {
      lambdaFunction: detectTypeFn,
      resultSelector: {
        'documentType.$': '$.Payload.documentType',
        'bucket.$': '$.Payload.bucket',
        'key.$': '$.Payload.key',
      },
      resultPath: '$.detection',
    });

    const extractTask = new tasks.LambdaInvoke(this, 'ExtractTextTask', {
      lambdaFunction: extractTextFn,
      payload: stepfunctions.TaskInput.fromObject({
        bucket: stepfunctions.JsonPath.stringAt('$.detection.bucket'),
        key: stepfunctions.JsonPath.stringAt('$.detection.key'),
        documentType: stepfunctions.JsonPath.stringAt('$.detection.documentType'),
      }),
      resultSelector: { 'text.$': '$.Payload.text' },
      resultPath: '$.extraction',
      // Retry on transient failures
      retryOnServiceExceptions: true,
    });
    // Custom retry for Lambda throttling
    extractTask.addRetry({
      errors: ['Lambda.TooManyRequestsException'],
      interval: cdk.Duration.seconds(5),
      maxAttempts: 3,
      backoffRate: 2,
    });

    const chunkTask = new tasks.LambdaInvoke(this, 'ChunkTask', {
      lambdaFunction: chunkFn,
      payload: stepfunctions.TaskInput.fromObject({
        text: stepfunctions.JsonPath.stringAt('$.extraction.text'),
        key: stepfunctions.JsonPath.stringAt('$.detection.key'),
      }),
      resultSelector: { 'chunks.$': '$.Payload.chunks' },
      resultPath: '$.chunking',
    });

    // Map state: embed each chunk (with concurrency control)
    const embedMap = new stepfunctions.Map(this, 'EmbedChunks', {
      itemsPath: '$.chunking.chunks',
      maxConcurrency: 10, // Respect Bedrock throttling limits
      resultPath: '$.embeddings',
    });
    embedMap.itemProcessor(
      new tasks.LambdaInvoke(this, 'EmbedChunkTask', {
        lambdaFunction: embedFn,
        resultSelector: {
          'embedding.$': '$.Payload.embedding',
          'chunkText.$': '$.Payload.chunkText',
          'chunkIndex.$': '$.Payload.chunkIndex',
        },
      })
    );

    const storeTask = new tasks.LambdaInvoke(this, 'StoreTask', {
      lambdaFunction: storeFn,
      resultPath: '$.storage',
    });

    // Mark success
    const markSuccess = new tasks.DynamoUpdateItem(this, 'MarkSuccess', {
      table: statusTable,
      key: { documentKey: tasks.DynamoAttributeValue.fromString(stepfunctions.JsonPath.stringAt('$.detail.object.key')) },
      updateExpression: 'SET #s = :status, completedAt = :time',
      expressionAttributeNames: { '#s': 'status' },
      expressionAttributeValues: {
        ':status': tasks.DynamoAttributeValue.fromString('COMPLETED'),
        ':time': tasks.DynamoAttributeValue.fromString(stepfunctions.JsonPath.stringAt('$$.State.EnteredTime')),
      },
      resultPath: stepfunctions.JsonPath.DISCARD,
    });

    // Error handler
    const markFailed = new tasks.DynamoUpdateItem(this, 'MarkFailed', {
      table: statusTable,
      key: { documentKey: tasks.DynamoAttributeValue.fromString(stepfunctions.JsonPath.stringAt('$.detail.object.key')) },
      updateExpression: 'SET #s = :status, #e = :error',
      expressionAttributeNames: { '#s': 'status', '#e': 'error' },
      expressionAttributeValues: {
        ':status': tasks.DynamoAttributeValue.fromString('FAILED'),
        ':error': tasks.DynamoAttributeValue.fromString(stepfunctions.JsonPath.stringAt('$.error.Cause')),
      },
      resultPath: stepfunctions.JsonPath.DISCARD,
    });
    markFailed.next(new stepfunctions.Fail(this, 'PipelineFailed', {
      cause: 'Document processing failed after retries',
    }));

    // Wire the chain with error handling
    const processingChain = markProcessing
      .next(detectTask)
      .next(extractTask)
      .next(chunkTask)
      .next(embedMap)
      .next(storeTask)
      .next(markSuccess);

    // Catch any unhandled error in the processing chain
    processingChain.toSingleState('ProcessingBlock').addCatch(markFailed, {
      resultPath: '$.error',
    });

    // Full workflow
    const definition = checkIdempotency
      .next(alreadyProcessed.otherwise(processingChain));

    const stateMachine = new stepfunctions.StateMachine(this, 'DocProcessing', {
      definitionBody: stepfunctions.DefinitionBody.fromChainable(definition),
      stateMachineType: stepfunctions.StateMachineType.STANDARD, // Can run > 5 minutes
      timeout: cdk.Duration.minutes(30),
      logs: {
        destination: new logs.LogGroup(this, 'SfnLogs', {
          retention: logs.RetentionDays.TWO_WEEKS,
        }),
        level: stepfunctions.LogLevel.ERROR,
      },
    });

    // --- EventBridge rule: S3 ObjectCreated → Step Functions ---
    const processingRule = new events.Rule(this, 'NewDocumentRule', {
      eventPattern: {
        source: ['aws.s3'],
        detailType: ['Object Created'],
        detail: {
          bucket: { name: [docBucket.bucketName] },
          object: {
            key: [{ prefix: 'incoming/' }], // Only process from incoming/ prefix
          },
        },
      },
    });

    processingRule.addTarget(new targets.SfnStateMachine(stateMachine, {
      deadLetterQueue: pipelineDlq, // Catch EventBridge delivery failures
      retryAttempts: 2,
    }));

    // --- Outputs ---
    new cdk.CfnOutput(this, 'BucketName', { value: docBucket.bucketName });
    new cdk.CfnOutput(this, 'StateMachineArn', { value: stateMachine.stateMachineArn });
    new cdk.CfnOutput(this, 'StatusTableName', { value: statusTable.tableName });
  }
}
```

### What's Optional vs. Required

| Component | Required? | Why |
|-----------|-----------|-----|
| `eventBridgeEnabled: true` on bucket | **Required** | EventBridge rules won't fire without this flag |
| EventBridge prefix filter (`incoming/`) | **Required** | Without it, processing triggers on ALL objects including outputs - circular! |
| Idempotency check | **Required** | S3 events can be delivered more than once; EventBridge guarantees at-least-once |
| Status tracking in DynamoDB | **Required** (per prompt) | User asked for status tracking; also enables the idempotency check |
| DLQ on EventBridge target | **Required** | If Step Functions is at capacity, events are lost without DLQ |
| Map state concurrency limit | **Required** | Without it, a 1000-chunk document fires 1000 parallel Bedrock calls = instant throttling |
| Standard workflow (vs. Express) | **Required** | Documents > 6MB with Textract can take > 5 minutes |
| Retry on extractTask | Recommended | Textract/PDF processing has transient failures |
| S3 versioning | Optional | Helpful for debugging but not required for the pipeline |
| Separate Lambda per step | Depends | Could merge detect+extract if they always run together; separate gives clearer error attribution |

### Common Agent Mistakes at This Complexity Level

1. **Circular trigger** - Output is written to the same bucket without a prefix filter. The store step writes embeddings → triggers a new processing event → infinite loop. **Always** use prefix filtering or separate buckets.

2. **Forgetting `eventBridgeEnabled: true`** - The EventBridge rule deploys successfully but never fires. This is the most common "it deployed but nothing happens" bug.

3. **Lambda timeout too short for large documents** - A 50-page PDF with PyPDF2 can take 60+ seconds. Agents often leave the default 3-second timeout.

4. **Map state without `maxConcurrency`** - A 500-chunk document fires 500 parallel Lambda invocations, all calling Bedrock simultaneously. Bedrock throttles, all fail, the whole workflow fails.

5. **Using Express workflow for document processing** - Express workflows have a 5-minute max. Large documents with Textract can take 10+ minutes. Use Standard workflow.

6. **EventBridge rule without DLQ** - If the Step Functions execution quota is reached (default 1M), EventBridge drops events silently without a DLQ.

7. **No idempotency check** - S3 → EventBridge delivers at-least-once. Without a dedup check, the same document gets processed multiple times, wasting compute and creating duplicate vectors.

---

## Pattern 4: API Composition with Bedrock Agents

### The Prompt

> "Build a Bedrock Agent that can look up customer information, check order status, and initiate refunds. It has a knowledge base for product FAQs and should route between action groups based on user intent."

### What the Agent Should Clarify First

1. **Action group boundaries**: Should these be one action group with multiple operations, or separate action groups?
   - Same domain/auth context → One action group (e.g., "OrderManagement" with getOrder, initiateRefund)
   - Different auth/backends → Separate action groups (e.g., "CustomerLookup" vs. "RefundProcessing")
   - Bedrock Agents route between action groups automatically based on the OpenAPI schema descriptions

2. **Return control vs. Lambda execution**: Should the agent call Lambda directly or return control to the caller?
   - Lambda execution: Agent calls Lambda and gets response inline (most common)
   - Return control: Agent pauses, returns proposed action to client, client executes and sends result back (for human-in-the-loop or when client has credentials the agent doesn't)

3. **Knowledge base scope**: What's in the KB vs. what requires live API calls?
   - Static product info, FAQs, policies → Knowledge Base
   - Customer-specific data, real-time status → Action Groups

4. **Guardrails**: Any content filtering needed? PII handling?
   - Determines whether to attach a Guardrail to the agent

### The Correct CDK Implementation

```typescript
import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import * as bedrock from 'aws-cdk-lib/aws-bedrock';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as iam from 'aws-cdk-lib/aws-iam';

export class BedrockAgentStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    // --- Agent execution role ---
    const agentRole = new iam.Role(this, 'AgentRole', {
      assumedBy: new iam.ServicePrincipal('bedrock.amazonaws.com'),
      inlinePolicies: {
        BedrockModel: new iam.PolicyDocument({
          statements: [new iam.PolicyStatement({
            actions: ['bedrock:InvokeModel'],
            resources: [
              `arn:aws:bedrock:${this.region}::foundation-model/anthropic.claude-3-sonnet-20240229-v1:0`,
            ],
          })],
        }),
      },
    });

    // --- Knowledge Base for product FAQs ---
    const kbBucket = new s3.Bucket(this, 'KnowledgeBaseBucket', {
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });

    // KB role needs S3 read + Bedrock embedding + AOSS access
    const kbRole = new iam.Role(this, 'KBRole', {
      assumedBy: new iam.ServicePrincipal('bedrock.amazonaws.com'),
      inlinePolicies: {
        S3Access: new iam.PolicyDocument({
          statements: [new iam.PolicyStatement({
            actions: ['s3:GetObject', 's3:ListBucket'],
            resources: [kbBucket.bucketArn, `${kbBucket.bucketArn}/*`],
          })],
        }),
        BedrockEmbed: new iam.PolicyDocument({
          statements: [new iam.PolicyStatement({
            actions: ['bedrock:InvokeModel'],
            resources: [`arn:aws:bedrock:${this.region}::foundation-model/amazon.titan-embed-text-v2:0`],
          })],
        }),
      },
    });

    // --- Action Group Lambda: Order Management ---
    const orderActionFn = new lambda.Function(this, 'OrderActionHandler', {
      runtime: lambda.Runtime.PYTHON_3_12,
      handler: 'order_actions.handler',
      code: lambda.Code.fromAsset('lambda/order-actions'),
      timeout: cdk.Duration.seconds(30),
      environment: {
        ORDERS_TABLE: 'REPLACE_WITH_TABLE_NAME',
      },
    });

    // --- Action Group Lambda: Customer Lookup ---
    const customerActionFn = new lambda.Function(this, 'CustomerActionHandler', {
      runtime: lambda.Runtime.PYTHON_3_12,
      handler: 'customer_actions.handler',
      code: lambda.Code.fromAsset('lambda/customer-actions'),
      timeout: cdk.Duration.seconds(30),
      environment: {
        CUSTOMERS_TABLE: 'REPLACE_WITH_TABLE_NAME',
      },
    });

    // Grant Bedrock permission to invoke the Lambda functions
    orderActionFn.grantInvoke(new iam.ServicePrincipal('bedrock.amazonaws.com'));
    customerActionFn.grantInvoke(new iam.ServicePrincipal('bedrock.amazonaws.com'));

    // --- Bedrock Agent (L1 construct - CfnAgent) ---
    const agent = new bedrock.CfnAgent(this, 'CustomerServiceAgent', {
      agentName: 'customer-service-agent',
      agentResourceRoleArn: agentRole.roleArn,
      foundationModel: 'anthropic.claude-3-sonnet-20240229-v1:0',
      instruction: `You are a customer service agent. You help customers check order status,
look up their account information, and process refunds when appropriate.
Always verify the customer's identity before accessing their information.
For product questions, check the knowledge base first.
Only initiate refunds for orders within the 30-day return window.`,

      actionGroups: [
        {
          actionGroupName: 'OrderManagement',
          description: 'Look up order status and process refunds for customer orders',
          actionGroupExecutor: {
            lambda: orderActionFn.functionArn,
          },
          apiSchema: {
            payload: JSON.stringify({
              openapi: '3.0.0',
              info: { title: 'Order Management', version: '1.0.0' },
              paths: {
                '/getOrderStatus': {
                  get: {
                    operationId: 'getOrderStatus',
                    description: 'Get the current status of a customer order including shipping tracking',
                    parameters: [{
                      name: 'orderId',
                      in: 'query',
                      required: true,
                      schema: { type: 'string' },
                      description: 'The unique order identifier (e.g., ORD-12345)',
                    }],
                    responses: {
                      '200': {
                        description: 'Order status details',
                        content: {
                          'application/json': {
                            schema: {
                              type: 'object',
                              properties: {
                                orderId: { type: 'string' },
                                status: { type: 'string', enum: ['pending', 'shipped', 'delivered', 'cancelled'] },
                                trackingNumber: { type: 'string' },
                                estimatedDelivery: { type: 'string' },
                              },
                            },
                          },
                        },
                      },
                    },
                  },
                },
                '/initiateRefund': {
                  post: {
                    operationId: 'initiateRefund',
                    description: 'Initiate a refund for an order. Only works for orders within 30-day return window.',
                    requestBody: {
                      required: true,
                      content: {
                        'application/json': {
                          schema: {
                            type: 'object',
                            required: ['orderId', 'reason'],
                            properties: {
                              orderId: { type: 'string', description: 'Order ID to refund' },
                              reason: { type: 'string', description: 'Customer reason for refund' },
                            },
                          },
                        },
                      },
                    },
                    responses: {
                      '200': {
                        description: 'Refund initiation result',
                        content: {
                          'application/json': {
                            schema: {
                              type: 'object',
                              properties: {
                                refundId: { type: 'string' },
                                status: { type: 'string' },
                                estimatedProcessingDays: { type: 'integer' },
                              },
                            },
                          },
                        },
                      },
                    },
                  },
                },
              },
            }),
          },
        },
        {
          actionGroupName: 'CustomerLookup',
          description: 'Look up customer account information and order history',
          actionGroupExecutor: {
            lambda: customerActionFn.functionArn,
          },
          apiSchema: {
            payload: JSON.stringify({
              openapi: '3.0.0',
              info: { title: 'Customer Lookup', version: '1.0.0' },
              paths: {
                '/getCustomerInfo': {
                  get: {
                    operationId: 'getCustomerInfo',
                    description: 'Look up customer account details by email or customer ID',
                    parameters: [
                      {
                        name: 'customerId',
                        in: 'query',
                        required: false,
                        schema: { type: 'string' },
                        description: 'Customer ID (if known)',
                      },
                      {
                        name: 'email',
                        in: 'query',
                        required: false,
                        schema: { type: 'string' },
                        description: 'Customer email address',
                      },
                    ],
                    responses: {
                      '200': {
                        description: 'Customer information',
                        content: {
                          'application/json': {
                            schema: {
                              type: 'object',
                              properties: {
                                customerId: { type: 'string' },
                                name: { type: 'string' },
                                email: { type: 'string' },
                                memberSince: { type: 'string' },
                                recentOrders: {
                                  type: 'array',
                                  items: {
                                    type: 'object',
                                    properties: {
                                      orderId: { type: 'string' },
                                      date: { type: 'string' },
                                      total: { type: 'number' },
                                    },
                                  },
                                },
                              },
                            },
                          },
                        },
                      },
                    },
                  },
                },
              },
            }),
          },
        },
      ],
    });

    // --- Outputs ---
    new cdk.CfnOutput(this, 'AgentId', { value: agent.attrAgentId });
    new cdk.CfnOutput(this, 'KBBucket', { value: kbBucket.bucketName });
  }
}
```

**Runtime: Action Group Lambda (Python)**

```python
# lambda/order-actions/order_actions.py
"""
Bedrock Agent action group Lambda handler.

CRITICAL: The response format MUST match what Bedrock Agents expects.
The agent will fail silently if the response format is wrong.
"""
import json
import os
import boto3

dynamodb = boto3.resource('dynamodb')
orders_table = dynamodb.Table(os.environ['ORDERS_TABLE'])


def handler(event, context):
    """
    Bedrock Agent Lambda handler.
    
    Event structure:
    {
        "actionGroup": "OrderManagement",
        "apiPath": "/getOrderStatus",
        "httpMethod": "GET",
        "parameters": [{"name": "orderId", "value": "ORD-12345"}],
        "requestBody": {...},  # For POST/PUT
        "messageVersion": "1.0"
    }
    """
    action_group = event.get('actionGroup')
    api_path = event.get('apiPath')
    http_method = event.get('httpMethod')
    parameters = {p['name']: p['value'] for p in event.get('parameters', [])}
    
    # Route to handler based on path
    if api_path == '/getOrderStatus' and http_method == 'GET':
        result = get_order_status(parameters.get('orderId'))
    elif api_path == '/initiateRefund' and http_method == 'POST':
        body = json.loads(event.get('requestBody', {}).get('content', {}).get('application/json', {}).get('properties', '{}'))
        result = initiate_refund(body.get('orderId'), body.get('reason'))
    else:
        result = {'error': f'Unknown action: {api_path}'}

    # CRITICAL: Response format for Bedrock Agents
    # This exact structure is required - deviating causes silent failures
    return {
        'messageVersion': '1.0',
        'response': {
            'actionGroup': action_group,
            'apiPath': api_path,
            'httpMethod': http_method,
            'httpStatusCode': 200,
            'responseBody': {
                'application/json': {
                    'body': json.dumps(result)
                }
            }
        }
    }


def get_order_status(order_id: str) -> dict:
    response = orders_table.get_item(Key={'orderId': order_id})
    item = response.get('Item')
    if not item:
        return {'error': f'Order {order_id} not found'}
    return {
        'orderId': item['orderId'],
        'status': item['status'],
        'trackingNumber': item.get('trackingNumber', 'Not yet available'),
        'estimatedDelivery': item.get('estimatedDelivery', 'Unknown'),
    }


def initiate_refund(order_id: str, reason: str) -> dict:
    # Business logic: check return window, etc.
    response = orders_table.get_item(Key={'orderId': order_id})
    item = response.get('Item')
    if not item:
        return {'error': f'Order {order_id} not found'}
    if item.get('status') == 'cancelled':
        return {'error': 'Order is already cancelled'}
    
    # Process refund...
    return {
        'refundId': f'REF-{order_id}',
        'status': 'initiated',
        'estimatedProcessingDays': 5,
    }
```

### What's Optional vs. Required

| Component | Required? | Why |
|-----------|-----------|-----|
| OpenAPI schema for each action group | **Required** | Bedrock Agents uses this to understand what actions are available |
| Detailed `description` on each operation | **Required** | The agent uses descriptions to decide WHEN to call each action - vague descriptions = wrong routing |
| Response schema in OpenAPI | Recommended | Helps the agent understand what it got back; not strictly required for function |
| `messageVersion: '1.0'` in Lambda response | **Required** | Response is rejected without it |
| `responseBody` wrapper in Lambda response | **Required** | Must be `{'application/json': {'body': json.dumps(...)}}` exactly |
| Knowledge Base (separate from action groups) | Depends | Only if there's static content; user specified FAQ use case |
| Guardrail attachment | Optional | Only if content filtering/PII masking needed |
| Agent alias for versioning | **Required for production** | You can't invoke an agent without an alias (except TSTALIASID for testing) |
| Separate action groups per domain | Recommended | Cleaner separation; agent can describe each group's purpose to itself |

### Common Agent Mistakes at This Complexity Level

1. **Wrong Lambda response format** - The most common failure. Bedrock Agents requires the exact response structure shown above. Missing `messageVersion`, wrong nesting of `responseBody`, or returning a plain dict all cause silent failures where the agent says "I couldn't complete that action."

2. **Overly broad action group schemas** - Putting 20 operations in one action group with vague descriptions. The agent can't decide which to call. Keep action groups focused (3-5 operations) with precise descriptions.

3. **Missing `grantInvoke` to bedrock.amazonaws.com** - The agent is created but can't call the Lambda. The invoke will fail with an access denied that surfaces as a generic "action failed" to the user.

4. **No agent alias** - Calling `InvokeAgent` API without creating an alias first. The agent exists but isn't invokable (except via `TSTALIASID` which is only for console testing).

5. **Confusing request body parsing** - For POST operations, the event structure nests the body under `requestBody.content.application/json.properties`. Agents often try to parse `event['body']` which doesn't exist.

6. **Knowledge Base without proper sync** - Creating the KB data source but not triggering a sync. The KB exists but has no data. Must call `StartIngestionJob` after deployment.

7. **OpenAPI schema without response definitions** - The agent can call the action but can't interpret what came back, leading to generic responses like "I called the order service" instead of "Your order ORD-12345 shipped on Tuesday."

---

## Pattern 5: Real-Time Streaming with Guardrails

### The Prompt

> "Build a WebSocket API that streams Bedrock model responses to the client in real-time with guardrails applied. Users connect via WebSocket, send messages, and receive streamed tokens back. Track connections in DynamoDB."

### What the Agent Should Clarify First

1. **Guardrail placement**: Apply guardrails to input only, output only, or both?
   - Input + output → Use `guardrailIdentifier` and `guardrailVersion` in `invoke_model_with_response_stream`
   - Output only → Can also use `ApplyGuardrail` API post-hoc (but loses streaming benefit)

2. **Connection management**: How long do connections stay open? Any auth on connect?
   - WebSocket APIs support Lambda/IAM authorizers on `$connect`
   - Connections should have TTL in DynamoDB for cleanup

3. **Conversation history**: Stateless (client sends full history) or stateful (server maintains)?
   - Stateless: Simpler, client sends all messages each time
   - Stateful: Server stores in DynamoDB, retrieved on each message

4. **Multi-turn vs. single-shot**: Does the model need conversation context?
   - Single-shot → Just stream the response
   - Multi-turn → Must manage `messages` array, store/retrieve conversation state

### The Correct CDK Implementation

```typescript
import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import * as apigatewayv2 from 'aws-cdk-lib/aws-apigatewayv2';
import * as integrations from 'aws-cdk-lib/aws-apigatewayv2-integrations';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import * as iam from 'aws-cdk-lib/aws-iam';

export class StreamingWithGuardrailsStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    // --- Connection tracking table ---
    const connectionsTable = new dynamodb.Table(this, 'ConnectionsTable', {
      partitionKey: { name: 'connectionId', type: dynamodb.AttributeType.STRING },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      timeToLiveAttribute: 'ttl', // Auto-clean stale connections
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    // --- Conversation history table (optional, for multi-turn) ---
    const conversationTable = new dynamodb.Table(this, 'ConversationTable', {
      partitionKey: { name: 'connectionId', type: dynamodb.AttributeType.STRING },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      timeToLiveAttribute: 'ttl',
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    // --- WebSocket API ---
    const webSocketApi = new apigatewayv2.WebSocketApi(this, 'StreamingApi', {
      apiName: 'bedrock-streaming-api',
      // Route selection expression determines which route handles a message
      routeSelectionExpression: '$request.body.action',
    });

    const stage = new apigatewayv2.WebSocketStage(this, 'ProdStage', {
      webSocketApi,
      stageName: 'prod',
      autoDeploy: true,
    });

    // --- Lambda: $connect handler ---
    const connectFn = new lambda.Function(this, 'ConnectHandler', {
      runtime: lambda.Runtime.PYTHON_3_12,
      handler: 'connect.handler',
      code: lambda.Code.fromAsset('lambda/websocket'),
      timeout: cdk.Duration.seconds(10),
      environment: {
        CONNECTIONS_TABLE: connectionsTable.tableName,
      },
    });
    connectionsTable.grantWriteData(connectFn);

    // --- Lambda: $disconnect handler ---
    const disconnectFn = new lambda.Function(this, 'DisconnectHandler', {
      runtime: lambda.Runtime.PYTHON_3_12,
      handler: 'disconnect.handler',
      code: lambda.Code.fromAsset('lambda/websocket'),
      timeout: cdk.Duration.seconds(10),
      environment: {
        CONNECTIONS_TABLE: connectionsTable.tableName,
      },
    });
    connectionsTable.grantWriteData(disconnectFn);

    // --- Lambda: message handler (streaming) ---
    const messageFn = new lambda.Function(this, 'MessageHandler', {
      runtime: lambda.Runtime.PYTHON_3_12,
      handler: 'message.handler',
      code: lambda.Code.fromAsset('lambda/websocket'),
      timeout: cdk.Duration.minutes(5), // Streaming can take time for long responses
      memorySize: 512,
      environment: {
        CONNECTIONS_TABLE: connectionsTable.tableName,
        CONVERSATION_TABLE: conversationTable.tableName,
        MODEL_ID: 'anthropic.claude-3-sonnet-20240229-v1:0',
        GUARDRAIL_ID: 'REPLACE_WITH_GUARDRAIL_ID',
        GUARDRAIL_VERSION: 'DRAFT', // Use specific version in production
        WEBSOCKET_ENDPOINT: `https://${webSocketApi.apiId}.execute-api.${this.region}.amazonaws.com/${stage.stageName}`,
      },
    });
    connectionsTable.grantReadData(messageFn);
    conversationTable.grantReadWriteData(messageFn);

    // Bedrock access (model invocation + guardrails)
    messageFn.addToRolePolicy(new iam.PolicyStatement({
      actions: [
        'bedrock:InvokeModelWithResponseStream',
        'bedrock:InvokeModel',
      ],
      resources: [
        `arn:aws:bedrock:${this.region}::foundation-model/anthropic.claude-3-sonnet-20240229-v1:0`,
      ],
    }));

    messageFn.addToRolePolicy(new iam.PolicyStatement({
      actions: ['bedrock:ApplyGuardrail'],
      resources: [`arn:aws:bedrock:${this.region}:${this.account}:guardrail/*`],
    }));

    // API Gateway management API (to post messages back to WebSocket clients)
    messageFn.addToRolePolicy(new iam.PolicyStatement({
      actions: ['execute-api:ManageConnections'],
      resources: [
        `arn:aws:execute-api:${this.region}:${this.account}:${webSocketApi.apiId}/${stage.stageName}/POST/@connections/*`,
      ],
    }));

    // --- WebSocket routes ---
    // $connect route (fires when client connects)
    webSocketApi.addRoute('$connect', {
      integration: new integrations.WebSocketLambdaIntegration('ConnectIntegration', connectFn),
    });

    // $disconnect route (fires when client disconnects)
    webSocketApi.addRoute('$disconnect', {
      integration: new integrations.WebSocketLambdaIntegration('DisconnectIntegration', disconnectFn),
    });

    // $default route (fires for any message without a matching route)
    webSocketApi.addRoute('$default', {
      integration: new integrations.WebSocketLambdaIntegration('DefaultIntegration', messageFn),
    });

    // Named route: "sendMessage" (matches when body.action == "sendMessage")
    webSocketApi.addRoute('sendMessage', {
      integration: new integrations.WebSocketLambdaIntegration('SendMessageIntegration', messageFn),
    });

    // --- Outputs ---
    new cdk.CfnOutput(this, 'WebSocketUrl', {
      value: `wss://${webSocketApi.apiId}.execute-api.${this.region}.amazonaws.com/${stage.stageName}`,
    });
  }
}
```

**Runtime: WebSocket Handlers (Python)**

```python
# lambda/websocket/connect.py
import os
import time
import boto3

dynamodb = boto3.resource('dynamodb')
table = dynamodb.Table(os.environ['CONNECTIONS_TABLE'])


def handler(event, context):
    """Handle $connect - store connection ID."""
    connection_id = event['requestContext']['connectionId']
    
    table.put_item(Item={
        'connectionId': connection_id,
        'connectedAt': int(time.time()),
        'ttl': int(time.time()) + 86400,  # 24-hour TTL
    })
    
    return {'statusCode': 200}
```

```python
# lambda/websocket/disconnect.py
import os
import boto3

dynamodb = boto3.resource('dynamodb')
table = dynamodb.Table(os.environ['CONNECTIONS_TABLE'])


def handler(event, context):
    """Handle $disconnect - remove connection record."""
    connection_id = event['requestContext']['connectionId']
    table.delete_item(Key={'connectionId': connection_id})
    return {'statusCode': 200}
```

```python
# lambda/websocket/message.py
"""
Handle incoming WebSocket messages: stream Bedrock response back with guardrails.

Key concept: We use the API Gateway Management API to POST chunks back to the
client's WebSocket connection as the Bedrock stream produces them.
"""
import os
import json
import time
import boto3

dynamodb = boto3.resource('dynamodb')
conversation_table = dynamodb.Table(os.environ['CONVERSATION_TABLE'])
bedrock = boto3.client('bedrock-runtime')

WEBSOCKET_ENDPOINT = os.environ['WEBSOCKET_ENDPOINT']
MODEL_ID = os.environ['MODEL_ID']
GUARDRAIL_ID = os.environ['GUARDRAIL_ID']
GUARDRAIL_VERSION = os.environ['GUARDRAIL_VERSION']


def handler(event, context):
    connection_id = event['requestContext']['connectionId']
    domain = event['requestContext']['domainName']
    stage = event['requestContext']['stage']
    
    # API Gateway Management API client
    apigw = boto3.client(
        'apigatewaymanagementapi',
        endpoint_url=f'https://{domain}/{stage}',
    )
    
    try:
        body = json.loads(event.get('body', '{}'))
        user_message = body.get('message', '')
        
        if not user_message:
            post_to_connection(apigw, connection_id, {
                'type': 'error',
                'message': 'No message provided',
            })
            return {'statusCode': 400}
        
        # Retrieve conversation history (multi-turn)
        conversation = get_conversation(connection_id)
        conversation.append({'role': 'user', 'content': [{'text': user_message}]})
        
        # Invoke Bedrock with streaming + guardrails
        response = bedrock.invoke_model_with_response_stream(
            modelId=MODEL_ID,
            body=json.dumps({
                'anthropic_version': 'bedrock-2023-05-31',
                'max_tokens': 4096,
                'messages': conversation,
            }),
            guardrailIdentifier=GUARDRAIL_ID,
            guardrailVersion=GUARDRAIL_VERSION,
        )
        
        # Stream chunks back to client
        full_response = ''
        for event_chunk in response['body']:
            chunk = json.loads(event_chunk['chunk']['bytes'])
            
            # Handle different event types in the stream
            if chunk['type'] == 'content_block_delta':
                delta_text = chunk['delta'].get('text', '')
                full_response += delta_text
                post_to_connection(apigw, connection_id, {
                    'type': 'delta',
                    'text': delta_text,
                })
            
            elif chunk['type'] == 'message_stop':
                # Check if guardrail intervened
                stop_reason = chunk.get('amazon-bedrock-guardrailAction')
                if stop_reason == 'INTERVENED':
                    # Guardrail blocked the response - notify client
                    post_to_connection(apigw, connection_id, {
                        'type': 'guardrail_intervened',
                        'message': 'Response was filtered by content policy.',
                    })
                    # Don't save blocked response to conversation history
                    return {'statusCode': 200}
            
            elif chunk['type'] == 'message_delta':
                # Final message metadata (stop_reason, usage)
                stop_reason = chunk.get('delta', {}).get('stop_reason')
                post_to_connection(apigw, connection_id, {
                    'type': 'done',
                    'stop_reason': stop_reason,
                })
        
        # Save to conversation history
        conversation.append({'role': 'assistant', 'content': [{'text': full_response}]})
        save_conversation(connection_id, conversation)
        
    except apigw.exceptions.GoneException:
        # Connection is stale - clean up
        dynamodb.Table(os.environ['CONNECTIONS_TABLE']).delete_item(
            Key={'connectionId': connection_id}
        )
    except Exception as e:
        try:
            post_to_connection(apigw, connection_id, {
                'type': 'error',
                'message': f'Internal error: {str(e)}',
            })
        except Exception:
            pass
        raise
    
    return {'statusCode': 200}


def post_to_connection(apigw, connection_id: str, data: dict):
    """Send data to a WebSocket connection."""
    apigw.post_to_connection(
        ConnectionId=connection_id,
        Data=json.dumps(data).encode('utf-8'),
    )


def get_conversation(connection_id: str) -> list:
    """Retrieve conversation history."""
    response = conversation_table.get_item(Key={'connectionId': connection_id})
    item = response.get('Item')
    if item and 'messages' in item:
        return json.loads(item['messages'])
    return []


def save_conversation(connection_id: str, messages: list):
    """Save conversation history with TTL."""
    conversation_table.put_item(Item={
        'connectionId': connection_id,
        'messages': json.dumps(messages),
        'updatedAt': int(time.time()),
        'ttl': int(time.time()) + 3600,  # 1-hour conversation TTL
    })
```

### What's Optional vs. Required

| Component | Required? | Why |
|-----------|-----------|-----|
| `$connect` route handler | **Required** | Without it, all connections are rejected (default deny) |
| `$disconnect` route handler | **Required** | Without cleanup, DynamoDB fills with stale connection IDs |
| `$default` route | Recommended | Catches messages that don't match named routes; prevents silent drops |
| `execute-api:ManageConnections` IAM | **Required** | Lambda can't post messages back to WebSocket without this |
| DynamoDB connections table with TTL | **Required** | WebSocket disconnects aren't always clean; TTL prevents stale records |
| Conversation history table | Optional | Only for multi-turn; stateless (client sends history) is simpler |
| Guardrail on streaming | Depends on requirements | User specified guardrails; without them, streaming is simpler |
| `GoneException` handling | **Required** | Clients disconnect unexpectedly; without this, Lambda errors on stale connections |
| Named routes (e.g., `sendMessage`) | Optional | Can use `$default` for everything; named routes help with multiple message types |
| Stage `autoDeploy: true` | Recommended for dev | Otherwise changes require manual deployment |

### Common Agent Mistakes at This Complexity Level

1. **Missing `$connect` and `$disconnect` routes** - These are not optional. Without `$connect`, all connection attempts fail. Without `$disconnect`, connection records accumulate forever.

2. **Wrong endpoint URL for Management API** - Must be `https://{domainName}/{stage}` from the event's `requestContext`, NOT the WebSocket URL (which uses `wss://`). This is the HTTP endpoint for the management API.

3. **Not handling guardrail `INTERVENED` in stream** - When a guardrail triggers mid-stream, the response changes format. Agents that only handle `content_block_delta` miss the guardrail intervention signal and either crash or send partial blocked content.

4. **Lambda timeout too short** - Long streaming responses (4096 tokens from Claude) can take 30-60 seconds. Default 3-second Lambda timeout kills the stream mid-response.

5. **Missing `execute-api:ManageConnections` permission** - The most common "connected but no messages come back" bug. The Lambda runs fine, processes the stream, but silently fails to post back because it can't call the Management API.

6. **Using REST API instead of WebSocket API** - API Gateway v1 (REST) and v2 (HTTP/WebSocket) are different constructs. WebSocket requires `apigatewayv2.WebSocketApi`, not `apigateway.RestApi`. Agents sometimes mix these up.

7. **Not handling `GoneException`** - When a client disconnects but the Lambda is still streaming, `post_to_connection` throws `GoneException`. Without a try/catch, the Lambda errors out and may retry (if invoked from a queue), wasting compute.

8. **Content type mismatch** - `post_to_connection` sends bytes. If the client expects text frames, you must encode as UTF-8. Sending raw bytes can cause client-side parsing failures.

---

## Summary: Legitimate Complexity Checklist

Before implementing any of these patterns, the agent should verify:

1. **Is this complexity required?** - Could Bedrock Knowledge Bases, a single Lambda, or a simpler service replace this architecture?
2. **Have I clarified the decision points?** - Scale, latency, access patterns determine which specific services are correct.
3. **Are all three layers of AWS security addressed?** - IAM policies (who can call the API), resource policies (who can access the resource), and encryption (data at rest and in transit).
4. **Do my timeouts chain correctly?** - SQS visibility > Lambda timeout. API Gateway timeout > Step Functions timeout > Lambda timeout.
5. **Is there an error path?** - DLQ, catch blocks, status tracking. Not speculative - production workloads WILL have failures.
6. **Am I using the right integration pattern?** - SDK integration vs. optimized integration in Step Functions. Sync vs. async. Express vs. Standard.
7. **Have I tested the response format?** - Bedrock Agents, WebSocket Management API, Step Functions - all have specific response formats that fail silently when wrong.
