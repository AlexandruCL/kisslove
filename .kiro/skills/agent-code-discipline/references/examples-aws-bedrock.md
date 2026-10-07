# AWS Bedrock & AgentCore Examples

Contrast examples demonstrating the four principles applied to Amazon Bedrock and AgentCore code (Python/TypeScript). Each shows what LLMs commonly generate vs. what you actually need.

## Table of Contents

1. [Invoke Model - Summarize (Python)](#1-bedrock-call-claude-to-summarize-a-document-python)
2. [Bedrock Agent with Knowledge Base (CDK TypeScript)](#2-bedrock-agents-create-an-agent-that-answers-questions-about-our-docs-cdk-typescript)
3. [Guardrails (Python)](#3-bedrock-add-guardrails-to-my-model-calls-python)
4. [Agent Runtime Loop (Python)](#4-agentcore-create-a-simple-agent-runtime-loop-python)

> **Note:** Model IDs in examples (e.g. `anthropic.claude-3-sonnet-*`) are illustrative.
> Always use the current model available in your Bedrock console.

---

## 1. Bedrock: "Call Claude to summarize a document" (Python)

### What LLMs Generate (Overcomplicated)

```python
import json
import time
import logging
from typing import Optional
from dataclasses import dataclass
from botocore.exceptions import ClientError, ReadTimeoutError
import boto3

logger = logging.getLogger(__name__)

@dataclass
class ModelConfig:
    model_id: str = "anthropic.claude-3-sonnet-20240229-v1:0"
    max_tokens: int = 4096
    temperature: float = 0.0
    top_p: float = 0.999
    region: str = "us-east-1"
    max_retries: int = 3
    retry_delay: float = 1.0

class BedrockSummarizer:
    def __init__(self, config: Optional[ModelConfig] = None):
        self.config = config or ModelConfig()
        self.client = boto3.client(
            "bedrock-runtime",
            region_name=self.config.region
        )
        self._token_count = 0

    def summarize(self, document: str, max_length: int = 500) -> str:
        """Summarize a document with retry logic and token tracking."""
        if not document or not document.strip():
            raise ValueError("Document cannot be empty")

        if len(document) > 100000:
            logger.warning("Document exceeds 100k chars, truncating")
            document = document[:100000]

        prompt = self._build_prompt(document, max_length)

        for attempt in range(self.config.max_retries):
            try:
                response = self._invoke_model(prompt)
                self._track_tokens(response)
                return self._extract_text(response)
            except ClientError as e:
                error_code = e.response['Error']['Code']
                if error_code == 'ThrottlingException':
                    wait = self.config.retry_delay * (2 ** attempt)
                    logger.warning(f"Throttled, retrying in {wait}s")
                    time.sleep(wait)
                elif error_code == 'ModelTimeoutException':
                    logger.error("Model timeout")
                    raise
                else:
                    raise
            except ReadTimeoutError:
                if attempt < self.config.max_retries - 1:
                    time.sleep(self.config.retry_delay)
                else:
                    raise

        raise RuntimeError("Max retries exceeded")

    def _build_prompt(self, document: str, max_length: int) -> str:
        return f"Summarize the following document in {max_length} words or fewer:\n\n{document}"

    def _invoke_model(self, prompt: str) -> dict:
        body = json.dumps({
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": self.config.max_tokens,
            "temperature": self.config.temperature,
            "top_p": self.config.top_p,
            "messages": [{"role": "user", "content": prompt}],
        })
        response = self.client.invoke_model(
            modelId=self.config.model_id,
            body=body,
            contentType="application/json",
            accept="application/json",
        )
        return json.loads(response["body"].read())

    def _extract_text(self, response: dict) -> str:
        return response["content"][0]["text"]

    def _track_tokens(self, response: dict):
        usage = response.get("usage", {})
        self._token_count += usage.get("input_tokens", 0)
        self._token_count += usage.get("output_tokens", 0)

    @property
    def total_tokens(self) -> int:
        return self._token_count
```

### Problems
- Created a class with config dataclass for a single function call
- Added retry logic with exponential backoff (SDK already handles retries)
- Added token tracking (not requested)
- Added document truncation logic (not requested)
- Added input validation that isn't part of the ask
- Hardcoded `top_p` and temperature without being asked about them
- 80+ lines for what is a 10-line operation

### What You Actually Need

```python
import json
import boto3

bedrock = boto3.client("bedrock-runtime")

def summarize(document: str) -> str:
    """Summarize a document using Claude on Bedrock."""
    response = bedrock.invoke_model(
        modelId="anthropic.claude-3-sonnet-20240229-v1:0",
        body=json.dumps({
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": 1024,
            "messages": [{"role": "user", "content": f"Summarize this document:\n\n{document}"}],
        }),
    )
    return json.loads(response["body"].read())["content"][0]["text"]
```

**Add later when needed:** Retry logic when you hit throttling in production. Token tracking when you need cost monitoring. Streaming when latency matters.
---

## 2. Bedrock Agents: "Create an agent that answers questions about our docs" (CDK TypeScript)

### What LLMs Generate (Overcomplicated)

```typescript
import * as cdk from 'aws-cdk-lib';
import * as bedrock from 'aws-cdk-lib/aws-bedrock';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as opensearch from 'aws-cdk-lib/aws-opensearchserverless';

export class AgentStack extends cdk.Stack {
  constructor(scope: cdk.App, id: string) {
    super(scope, id);

    // Vector store for knowledge base
    const collection = new opensearch.CfnCollection(this, 'VectorStore', {
      name: 'docs-vectors',
      type: 'VECTORSEARCH',
    });

    // Encryption policy
    new opensearch.CfnSecurityPolicy(this, 'EncryptionPolicy', {
      name: 'docs-encryption',
      type: 'encryption',
      policy: JSON.stringify({
        Rules: [{ ResourceType: 'collection', Resource: [`collection/docs-vectors`] }],
        AWSOwnedKey: true,
      }),
    });

    // Network policy
    new opensearch.CfnSecurityPolicy(this, 'NetworkPolicy', {
      name: 'docs-network',
      type: 'network',
      policy: JSON.stringify([{
        Rules: [
          { ResourceType: 'collection', Resource: [`collection/docs-vectors`] },
          { ResourceType: 'dashboard', Resource: [`collection/docs-vectors`] },
        ],
        AllowFromPublic: true,
      }]),
    });

    const docsBucket = new s3.Bucket(this, 'DocsBucket', {
      versioned: true,
      encryption: s3.BucketEncryption.S3_MANAGED,
    });

    // Knowledge base role
    const kbRole = new iam.Role(this, 'KBRole', {
      assumedBy: new iam.ServicePrincipal('bedrock.amazonaws.com'),
      inlinePolicies: {
        bedrock: new iam.PolicyDocument({
          statements: [
            new iam.PolicyStatement({
              actions: ['bedrock:InvokeModel'],
              resources: ['*'],
            }),
            new iam.PolicyStatement({
              actions: ['s3:GetObject', 's3:ListBucket'],
              resources: [docsBucket.bucketArn, `${docsBucket.bucketArn}/*`],
            }),
            new iam.PolicyStatement({
              actions: ['aoss:APIAccessAll'],
              resources: [collection.attrArn],
            }),
          ],
        }),
      },
    });

    // Agent role
    const agentRole = new iam.Role(this, 'AgentRole', {
      assumedBy: new iam.ServicePrincipal('bedrock.amazonaws.com'),
      inlinePolicies: {
        agent: new iam.PolicyDocument({
          statements: [
            new iam.PolicyStatement({
              actions: ['bedrock:InvokeModel', 'bedrock:Retrieve'],
              resources: ['*'],
            }),
          ],
        }),
      },
    });

    // Action group Lambda
    const actionLambda = new lambda.Function(this, 'ActionHandler', {
      runtime: lambda.Runtime.PYTHON_3_12,
      handler: 'index.handler',
      code: lambda.Code.fromAsset('lambda/action-group'),
      timeout: cdk.Duration.seconds(30),
    });

    // Knowledge base (L1 construct)
    const kb = new bedrock.CfnKnowledgeBase(this, 'KnowledgeBase', {
      name: 'docs-kb',
      roleArn: kbRole.roleArn,
      knowledgeBaseConfiguration: {
        type: 'VECTOR',
        vectorKnowledgeBaseConfiguration: {
          embeddingModelArn: `arn:aws:bedrock:${this.region}::foundation-model/amazon.titan-embed-text-v2:0`,
        },
      },
      storageConfiguration: {
        type: 'OPENSEARCH_SERVERLESS',
        opensearchServerlessConfiguration: {
          collectionArn: collection.attrArn,
          vectorIndexName: 'docs-index',
          fieldMapping: {
            vectorField: 'embedding',
            textField: 'text',
            metadataField: 'metadata',
          },
        },
      },
    });

    // Agent
    const agent = new bedrock.CfnAgent(this, 'Agent', {
      agentName: 'docs-agent',
      agentResourceRoleArn: agentRole.roleArn,
      foundationModel: 'anthropic.claude-3-sonnet-20240229-v1:0',
      instruction: 'You are a helpful assistant that answers questions about company documentation.',
      knowledgeBases: [{
        knowledgeBaseId: kb.attrKnowledgeBaseId,
        description: 'Company documentation',
      }],
      actionGroups: [{
        actionGroupName: 'DocumentActions',
        actionGroupExecutor: { lambda: actionLambda.functionArn },
        apiSchema: { payload: JSON.stringify({ /* full OpenAPI spec */ }) },
      }],
    });
  }
}
```

### Problems
- Built the entire OpenSearch Serverless infrastructure (150+ lines)
- Added an action group with Lambda that wasn't requested
- Created complex IAM roles manually
- Added encryption and network policies
- User just said "answers questions about docs" - this could be a simple KB + agent without action groups
- Assumed OpenSearch when Bedrock now supports managed vector stores

### What You Actually Need

```typescript
import * as cdk from 'aws-cdk-lib';
import * as bedrock from 'aws-cdk-lib/aws-bedrock';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as iam from 'aws-cdk-lib/aws-iam';

export class AgentStack extends cdk.Stack {
  constructor(scope: cdk.App, id: string) {
    super(scope, id);

    const docsBucket = new s3.Bucket(this, 'DocsBucket');

    const kbRole = new iam.Role(this, 'KBRole', {
      assumedBy: new iam.ServicePrincipal('bedrock.amazonaws.com'),
    });
    docsBucket.grantRead(kbRole);

    const agentRole = new iam.Role(this, 'AgentRole', {
      assumedBy: new iam.ServicePrincipal('bedrock.amazonaws.com'),
    });

    // Use Bedrock managed vector store (no OpenSearch infra needed)
    const kb = new bedrock.CfnKnowledgeBase(this, 'KB', {
      name: 'docs-kb',
      roleArn: kbRole.roleArn,
      knowledgeBaseConfiguration: {
        type: 'VECTOR',
        vectorKnowledgeBaseConfiguration: {
          embeddingModelArn: `arn:aws:bedrock:${this.region}::foundation-model/amazon.titan-embed-text-v2:0`,
        },
      },
      storageConfiguration: { type: 'BEDROCK_MANAGED' },
    });

    new bedrock.CfnAgent(this, 'Agent', {
      agentName: 'docs-agent',
      agentResourceRoleArn: agentRole.roleArn,
      foundationModel: 'anthropic.claude-3-sonnet-20240229-v1:0',
      instruction: 'Answer questions about company documentation.',
      knowledgeBases: [{
        knowledgeBaseId: kb.attrKnowledgeBaseId,
        description: 'Company docs',
      }],
    });
  }
}
```

**Questions to ask first:**
- Where are the docs? (existing S3 bucket, or new?)
- Do you need action groups or just Q&A over documents?
- What vector store? (Bedrock managed is simplest, OpenSearch if you need custom indexing)
- Is this dev/POC or production? (affects IAM granularity)
---

## 3. Bedrock: "Add guardrails to my model calls" (Python)

### What LLMs Generate (Overcomplicated)

```python
import json
import boto3
from typing import Optional, List
from dataclasses import dataclass, field
from enum import Enum

class ContentFilterStrength(Enum):
    NONE = "NONE"
    LOW = "LOW"
    MEDIUM = "MEDIUM"
    HIGH = "HIGH"

@dataclass
class GuardrailConfig:
    name: str
    blocked_topics: List[str] = field(default_factory=list)
    content_filter_strength: ContentFilterStrength = ContentFilterStrength.HIGH
    pii_entities: List[str] = field(default_factory=lambda: [
        "EMAIL", "PHONE", "SSN", "CREDIT_DEBIT_CARD_NUMBER",
        "AWS_ACCESS_KEY", "AWS_SECRET_KEY"
    ])
    word_filters: List[str] = field(default_factory=list)
    managed_word_lists: List[str] = field(default_factory=lambda: ["PROFANITY"])

class GuardrailManager:
    def __init__(self, region: str = "us-east-1"):
        self.client = boto3.client("bedrock", region_name=region)
        self.runtime = boto3.client("bedrock-runtime", region_name=region)

    def create_guardrail(self, config: GuardrailConfig) -> str:
        """Create a guardrail with full configuration."""
        topic_policy = None
        if config.blocked_topics:
            topic_policy = {
                "topicsConfig": [
                    {
                        "name": topic,
                        "definition": f"Content related to {topic}",
                        "type": "DENY",
                    }
                    for topic in config.blocked_topics
                ]
            }

        content_policy = {
            "filtersConfig": [
                {"type": t, "inputStrength": config.content_filter_strength.value,
                 "outputStrength": config.content_filter_strength.value}
                for t in ["SEXUAL", "VIOLENCE", "HATE", "INSULTS", "MISCONDUCT"]
            ]
        }

        sensitive_policy = {
            "piiEntitiesConfig": [
                {"type": entity, "action": "ANONYMIZE"}
                for entity in config.pii_entities
            ]
        }

        word_policy = {}
        if config.word_filters:
            word_policy["wordsConfig"] = [{"text": w} for w in config.word_filters]
        if config.managed_word_lists:
            word_policy["managedWordListsConfig"] = [
                {"type": w} for w in config.managed_word_lists
            ]

        params = {
            "name": config.name,
            "contentPolicyConfig": content_policy,
            "sensitiveInformationPolicyConfig": sensitive_policy,
            "blockedInputMessaging": "Your request was blocked by content filters.",
            "blockedOutputsMessaging": "The response was blocked by content filters.",
        }
        if topic_policy:
            params["topicPolicyConfig"] = topic_policy
        if word_policy:
            params["wordPolicyConfig"] = word_policy

        response = self.client.create_guardrail(**params)
        return response["guardrailId"]

    def invoke_with_guardrail(self, guardrail_id: str, guardrail_version: str,
                               model_id: str, prompt: str,
                               max_tokens: int = 1024) -> dict:
        """Invoke model with guardrail applied."""
        response = self.runtime.invoke_model(
            modelId=model_id,
            body=json.dumps({
                "anthropic_version": "bedrock-2023-05-31",
                "max_tokens": max_tokens,
                "messages": [{"role": "user", "content": prompt}],
            }),
            guardrailIdentifier=guardrail_id,
            guardrailVersion=guardrail_version,
        )
        result = json.loads(response["body"].read())
        # ... more processing
        return result
```

### Problems
- Built an entire "GuardrailManager" class with creation + invocation
- User said "add guardrails to my model calls" - they likely already have a guardrail ID
- Invented enum classes and dataclass configs
- Pre-populated PII entity lists with assumptions
- Mixed guardrail creation (one-time setup) with runtime invocation (per-call)

### What You Actually Need

If the guardrail already exists (most common case):

```python
import json
import boto3

bedrock = boto3.client("bedrock-runtime")

def invoke_with_guardrail(prompt: str, guardrail_id: str, guardrail_version: str = "DRAFT") -> str:
    """Invoke Claude with a guardrail."""
    response = bedrock.invoke_model(
        modelId="anthropic.claude-3-sonnet-20240229-v1:0",
        body=json.dumps({
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": 1024,
            "messages": [{"role": "user", "content": prompt}],
        }),
        guardrailIdentifier=guardrail_id,
        guardrailVersion=guardrail_version,
    )
    return json.loads(response["body"].read())["content"][0]["text"]
```

**Question to ask first:** Do you already have a guardrail configured, or do you need to create one? (These are separate concerns.)
---

## 4. AgentCore: "Create a simple agent runtime loop" (Python)

### What LLMs Generate (Overcomplicated)

```python
import json
import logging
import time
from typing import Any, Callable, Optional
from dataclasses import dataclass, field
from abc import ABC, abstractmethod

logger = logging.getLogger(__name__)

@dataclass
class ToolDefinition:
    name: str
    description: str
    parameters: dict
    handler: Callable[..., Any]

@dataclass
class AgentConfig:
    model_id: str = "anthropic.claude-3-sonnet-20240229-v1:0"
    max_turns: int = 10
    max_tokens: int = 4096
    temperature: float = 0.0
    system_prompt: str = "You are a helpful assistant."
    stop_sequences: list = field(default_factory=list)

class ToolRegistry:
    def __init__(self):
        self._tools: dict[str, ToolDefinition] = {}

    def register(self, tool: ToolDefinition):
        self._tools[tool.name] = tool

    def get(self, name: str) -> Optional[ToolDefinition]:
        return self._tools.get(name)

    def list_schemas(self) -> list[dict]:
        return [
            {"name": t.name, "description": t.description, "input_schema": t.parameters}
            for t in self._tools.values()
        ]

class ConversationMemory:
    def __init__(self, max_messages: int = 100):
        self.messages: list[dict] = []
        self.max_messages = max_messages

    def add(self, role: str, content: Any):
        self.messages.append({"role": role, "content": content})
        if len(self.messages) > self.max_messages:
            self.messages = self.messages[-self.max_messages:]

    def get_messages(self) -> list[dict]:
        return self.messages.copy()

class BaseAgent(ABC):
    @abstractmethod
    def run(self, user_input: str) -> str:
        pass

class BedrockAgent(BaseAgent):
    def __init__(self, config: AgentConfig, registry: ToolRegistry):
        self.config = config
        self.registry = registry
        self.memory = ConversationMemory()
        self.client = boto3.client("bedrock-runtime")

    def run(self, user_input: str) -> str:
        self.memory.add("user", user_input)

        for turn in range(self.config.max_turns):
            response = self._call_model()

            if response["stop_reason"] == "end_turn":
                text = self._extract_text(response)
                self.memory.add("assistant", response["content"])
                return text

            if response["stop_reason"] == "tool_use":
                self.memory.add("assistant", response["content"])
                tool_results = self._execute_tools(response["content"])
                self.memory.add("user", tool_results)

        raise RuntimeError(f"Agent exceeded {self.config.max_turns} turns")

    # ... another 50 lines of helper methods
```

### Problems
- Created abstract base class for a single agent implementation
- Built a ToolRegistry class (a dict with extra steps)
- Built a ConversationMemory class with truncation (a list with extra steps)
- Config dataclass with 6 fields for what could be function parameters
- 100+ lines before any actual agent logic runs
- Patterns like "Registry" and "Memory" classes are premature abstractions

### What You Actually Need

```python
import json
import boto3

bedrock = boto3.client("bedrock-runtime")

def run_agent(prompt: str, tools: list[dict], tool_handlers: dict, system: str = "") -> str:
    """Simple agent loop: call model, execute tools, repeat until done."""
    messages = [{"role": "user", "content": prompt}]

    for _ in range(10):  # max turns
        body = {
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": 4096,
            "messages": messages,
            "tools": tools,
        }
        if system:
            body["system"] = system

        response = json.loads(
            bedrock.invoke_model(
                modelId="anthropic.claude-3-sonnet-20240229-v1:0",
                body=json.dumps(body),
            )["body"].read()
        )

        if response["stop_reason"] == "end_turn":
            return next(b["text"] for b in response["content"] if b["type"] == "text")

        # Execute tool calls
        messages.append({"role": "assistant", "content": response["content"]})
        tool_results = []
        for block in response["content"]:
            if block["type"] == "tool_use":
                result = tool_handlers[block["name"]](**block["input"])
                tool_results.append({
                    "type": "tool_result",
                    "tool_use_id": block["id"],
                    "content": json.dumps(result),
                })
        messages.append({"role": "user", "content": tool_results})

    return "Max turns reached"
```

**When to add classes:** When you have multiple agents with different behaviors. When you need persistent conversation across sessions. When you need tool registration from multiple modules. Not for a single agent loop.

---

## Anti-Patterns Summary (AWS Domain)

| Scenario | LLM Over-Engineering | What's Actually Needed |
|----------|---------------------|----------------------|
| CDK Lambda + APIGW | Custom construct, props interface, X-Ray, CORS, throttling | `LambdaRestApi` one-liner |
| DynamoDB table | Provisioned + autoscaling + GSI + streams + alarms | On-demand + partition key + TTL |
| S3 processor | SQS + DLQ + lifecycle rules + CORS + versioning | Bucket + Lambda + notification |
| Bedrock invoke | Class hierarchy + retry + token tracking + validation | Single function, 10 lines |
| Bedrock Agent (CDK) | Full OpenSearch Serverless + action groups | Managed vector store + basic agent |
| Guardrails | Manager class + enum + dataclass + creation + invocation | Pass guardrail ID to invoke_model |
| Step Functions | Input validation + error handling + logging + tracing | One task, one state machine |
| Agent loop | ABC + Registry + Memory class + Config dataclass | One function with a for loop |

---

## Key Insight for AWS/CDK

CDK's L2 constructs already encapsulate best practices. LLMs tend to:
1. **Recreate what CDK gives you for free** (IAM roles, log groups, permissions)
2. **Add production hardening to POC code** (autoscaling, alarms, DLQs)
3. **Pick complex storage when simple exists** (OpenSearch vs. Bedrock managed)
4. **Build class hierarchies for single-use infrastructure**

The rule: **Start with the highest-level construct. Drop to L1 only when L2 can't express what you need.** And ask whether it's a POC or production before adding operational overhead.

---

## Anti-Patterns Summary (Bedrock/AgentCore)

| Scenario | LLM Over-Engineering | What's Actually Needed |
|----------|---------------------|----------------------|
| Bedrock invoke | Class hierarchy + retry + token tracking + validation | Single function, 10 lines |
| Bedrock Agent (CDK) | Full OpenSearch Serverless + action groups | Managed vector store + basic agent |
| Guardrails | Manager class + enum + dataclass + creation + invocation | Pass guardrail ID to invoke_model |
| Agent loop | ABC + Registry + Memory class + Config dataclass | One function with a for loop |

---

## Key Insight

LLMs tend to:
1. **Pick complex storage when simple exists** (OpenSearch vs. Bedrock managed vector store)
2. **Build class hierarchies for single API calls** (BedrockSummarizer class for one invoke_model)
3. **Mix one-time setup with runtime code** (guardrail creation + invocation in one class)
4. **Add retry/backoff logic the SDK already handles**

The rule: **Start with a single function. Add classes only when you have multiple callers with different behaviors.** The boto3 SDK already handles retries - don't reimplement them.
