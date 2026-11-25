// Copyright © 2026 Amazon.com and Affiliates. Licensed under MIT-0.

using System.Text.Json.Serialization;
using Amazon.Lambda.APIGatewayEvents;
using OrdersApi.Models;

namespace OrdersApi;

[JsonSerializable(typeof(OrderRequest))]
[JsonSerializable(typeof(OrderResponse))]
[JsonSerializable(typeof(APIGatewayProxyRequest))]
[JsonSerializable(typeof(APIGatewayProxyResponse))]
[JsonSourceGenerationOptions(
    PropertyNameCaseInsensitive = true,
    PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase)]
public partial class AppJsonContext : JsonSerializerContext
{
}
