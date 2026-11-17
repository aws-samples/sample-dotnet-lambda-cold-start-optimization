// Copyright © 2026 Amazon.com and Affiliates. Licensed under MIT-0.

using Amazon.DynamoDBv2;
using Amazon.DynamoDBv2.Model;
using OrdersApi.Models;

namespace OrdersApi.Services;

public class OrderRepository : IOrderRepository
{
    private readonly IAmazonDynamoDB _dynamoDb;
    private static readonly string TableName =
        Environment.GetEnvironmentVariable("ORDERS_TABLE_NAME") ?? "Orders";

    public OrderRepository(IAmazonDynamoDB dynamoDb)
    {
        _dynamoDb = dynamoDb;
    }

    public async Task<OrderResponse> SaveOrderAsync(OrderResponse order)
    {
        var item = new Dictionary<string, AttributeValue>
        {
            ["OrderId"] = new AttributeValue { S = order.OrderId },
            ["CustomerId"] = new AttributeValue { S = order.CustomerId },
            ["ProductId"] = new AttributeValue { S = order.ProductId },
            ["Quantity"] = new AttributeValue { N = order.Quantity.ToString() },
            ["Status"] = new AttributeValue { S = order.Status.ToString() },
            ["CreatedAt"] = new AttributeValue { S = order.CreatedAt.ToString("o") }
        };

        await _dynamoDb.PutItemAsync(new PutItemRequest
        {
            TableName = TableName,
            Item = item
        });

        return order;
    }
}
