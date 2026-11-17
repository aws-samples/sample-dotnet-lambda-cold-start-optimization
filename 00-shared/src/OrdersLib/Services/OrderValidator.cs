// Copyright © 2026 Amazon.com and Affiliates. Licensed under MIT-0.

using OrdersApi.Models;

namespace OrdersApi.Services;

public class OrderValidator : IOrderValidator
{
    public (bool IsValid, string? Error) Validate(OrderRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.CustomerId))
            return (false, "CustomerId is required.");

        if (string.IsNullOrWhiteSpace(request.ProductId))
            return (false, "ProductId is required.");

        if (request.Quantity <= 0)
            return (false, "Quantity must be greater than zero.");

        return (true, null);
    }
}
