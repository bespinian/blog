---
title: Level Up Your Serverless Game
author: Lena Fuhrimann
comments: true
date: 2025-02-25
---

As external engineers, we've witnessed countless serverless projects stumble
through the same growing pains while maturing their setup. From basic
misconfigurations to complex deployment nightmares, the patterns are
frustratingly consistent. We've compiled this blog post to help you avoid these
common pitfalls and accelerate your journey to serverless excellence. Think of
each level as a lesson learned, a mistake you don't have to make. To learn more
about the details and apply the learnings yourself, follow our open source
[Serverless Workshop](https://github.com/bespinian/serverless-workshop). This
blog post as well as the workshop both use AWS Lambda but the learnings can be
applied to any function as a service (FaaS) platform. Now, let's dive in.

## Level 0 - This is easy!

**⚠️ Mistake: None yet**

To get started, we need to create our first function. Many projects jump into
complex architectures without understanding the fundamentals, leading to
confusion and wasted effort. This level is about demystifying the basic
mechanics of serverless: understanding how to create a function, configure its
runtime, and pass parameters using environment variables. You should also get
acquainted with your cloud provider's permission model, a cornerstone of secure
serverless applications. By adding an HTTP trigger through an API gateway, you
can transform our function into a web-accessible service, making it tangible and
interactive.

**✅ Avoid neglecting the basics, and you'll build on a much stronger
foundation.**

## Level 1 - Loggin' it!

**⚠️ Mistake: Lack of structured logging**

Having deployed our first function, we have no idea what it does and if it
succeeds or not. When things go wrong, it's very hard to debug and investigate
issues. Many serverless projects suffer from poor observability, making
troubleshooting a nightmare. Using structured logging (e.g., formatted as JSON),
we get a set of logs that we can query and which give us custom insights into
what our function does. We'll know if it succeeds or fails in doing so and get
context about what went wrong if things don't go as expected. Such a log line
could look as follows:

```json
{
  "correlationId": "9ac54d82-75e0-4f0d-ae3c-e84ca400b3bd",
  "requestId": "58d9c96e-ae9f-43db-a353-c48e7a70bfa8",
  "commitHash": "9d9154e",
  "level": "INFO",
  "requestPath": "/users/1",
  "requestMethod": "GET",
  "responseCode": 200,
  "responseBody": "All good"
}
```

**✅ Don't wait until production issues arise to implement structured logging.**

## Level 2 - Tracin' it!

**⚠️ Mistake: Lack of distributed tracing**

As your serverless applications grow, understanding the flow of requests becomes
critical. Distributed tracing provides invaluable insights into performance
bottlenecks and errors. Most cloud providers provide comprehensive tool sets to
easily add tracing IDs and even trace HTTP calls and other function calls by
just adding a couple of lines of code. Therefore, it's usually quite cheap to
add tracing and the value it provides is quite large. A low-hanging fruit you
shouldn't miss out on.

**✅ Activate distributed tracing for all your functions.**

## Level 3: Timin' it!

**⚠️ Mistake: Function timeouts not handled gracefully**

Functions operate within time constraints, making it essential to handle
timeouts gracefully. Unhandled timeouts can lead to unexpected behavior and data
inconsistencies. We need to ensure our functions terminate cleanly and
predictably, even when approaching their time limits. To achieve that, simply
monitor the remaining execution time and implement mechanisms for aborting
long-running operations with enough time left. This allows to either perform a
proper cleanup or partial results instead, ensuring a smooth and reliable user
experience.

**✅ Don't let timeouts cause chaos in your application.**

## Level 4: Optimized Cold Starts!

**⚠️ Mistake: Ignoring cold start performance**

Cold starts, the initial latency experienced when a Lambda function is invoked
after a period of inactivity, can impact performance. In latency-sensitive
applications, even a few extra milliseconds can be noticeable to users. This
level explores techniques to minimize cold start times, such as moving
initialization code outside the handler. By optimizing our function's startup
process, we can enhance responsiveness and improve the overall user experience.

**✅ Optimize for cold starts early to avoid performance bottlenecks later.**

## Level 5: The Message Highway - Decoupling with SQS

**Mistake: Tight Coupling**

As our applications grow, the need for asynchronous communication becomes
paramount. **Why is this important?** Tight coupling between services can lead
to cascading failures and reduced scalability. This level introduces Amazon SQS,
a message queuing service, allowing us to decouple our Lambda functions and
create more scalable and resilient architectures. We'll learn how to send and
receive messages, enabling asynchronous workflows and event-driven processing.
**Decoupling is essential for building robust and scalable serverless
applications.**

## Level 6: Building the Blueprint - Infrastructure as Code with Terraform

**Manual Infrastructure Management**

For those ready to embrace infrastructure as code, this level introduces
Terraform, a powerful tool for managing and provisioning cloud resources. **Why
is this important?** Manual infrastructure management is error-prone and
time-consuming. This level teaches you how to define your Lambda functions and
their dependencies as code, enabling repeatable and version-controlled
deployments. This level is about automating infrastructure management and
embracing a more declarative approach to cloud resource provisioning. **Avoid
the chaos of manual deployments with infrastructure as code.**

## Level 7: The Test of Truth - Unit Testing and Local Execution

**Mistake: Lack of Testing**

Quality assurance is paramount in software development. **Why is this
important?** Untested code is a recipe for disaster. This level focuses on unit
testing our Lambda functions and running them locally for debugging. By writing
effective tests and simulating the Lambda environment, we can ensure our
functions are reliable and robust. **Testing is not an afterthought; it's a
fundamental part of the development process.**

## Level 8: The Fortress - Implementing Least Privilege

**Mistake: Overly Permissive Roles**

Security is a fundamental concern in cloud computing. **Why is this important?**
Overly permissive roles can expose your application to security vulnerabilities.
This level emphasizes the principle of least privilege, teaching us how to grant
our Lambda functions only the necessary permissions. By restricting access, we
can minimize the potential impact of security breaches and enhance the overall
security posture of our applications. **Security should be a priority from the
start.**

## Level 9: The Gradual Rollout - Canary Deployments with CodeDeploy

**Mistake: Risky Deployments**

Deploying new versions of our applications can be risky. **Why is this
important?** A bad deployment can bring down your entire application. This level
introduces canary deployments, a strategy for gradually rolling out changes to a
subset of users. By using AWS CodeDeploy, we can automate the deployment process
and minimize the impact of errors, ensuring a smooth and reliable user
experience. **Minimize risk with gradual deployments.**
