// Copyright © 2026 Amazon.com and Affiliates. Licensed under MIT-0.

using System.Text.Json;
using Amazon.DynamoDBv2;
using Amazon.Lambda.APIGatewayEvents;
using Amazon.Lambda.Core;
using Amazon.Lambda.RuntimeSupport;
using Amazon.Lambda.Serialization.SystemTextJson;
using Microsoft.Extensions.DependencyInjection;
using OrdersApi;
using OrdersApi.Models;
using OrdersApi.Services;

// Single purpose: one function, one route. API Gateway's event goes straight
// to the handler — no ASP.NET Core host, no Powertools. 03-native-aot-ready
// does the same work through both.
ServiceCollection services = new();
services.AddSingleton<IAmazonDynamoDB, AmazonDynamoDBClient>();
services.AddSingleton<IOrderValidator, OrderValidator>();
services.AddSingleton<IOrderRepository, OrderRepositoryAot>();
services.AddSingleton<IOrderService, OrderService>();

// Resolved during init, so the DynamoDB client is built before the first
// request rather than inside it.
IOrderService orderService = services.BuildServiceProvider()
    .GetRequiredService<IOrderService>();

async Task<APIGatewayProxyResponse> CreateOrderAsync(
    APIGatewayProxyRequest request, ILambdaContext context)
{
    try
    {
        OrderRequest? order = JsonSerializer.Deserialize(
            request.Body ?? "", AppJsonContext.Default.OrderRequest);
        if (order is null)
            return Respond(400, "Invalid request body.");

        OrderResponse response = await orderService.CreateOrderAsync(order);
        return Respond(200, JsonSerializer.Serialize(
            response, AppJsonContext.Default.OrderResponse));
    }
    catch (JsonException)
    {
        return Respond(400, "Invalid request body.");
    }
    catch (ArgumentException ex)
    {
        return Respond(400, ex.Message);
    }
}

static APIGatewayProxyResponse Respond(int statusCode, string body) => new()
{
    StatusCode = statusCode,
    Body = body,
    Headers = new Dictionary<string, string>
    {
        ["Content-Type"] = statusCode == 200
            ? "application/json" : "text/plain"
    }
};

await LambdaBootstrapBuilder
    .Create<APIGatewayProxyRequest, APIGatewayProxyResponse>(
        CreateOrderAsync,
        new SourceGeneratorLambdaJsonSerializer<AppJsonContext>())
    .Build()
    .RunAsync();
