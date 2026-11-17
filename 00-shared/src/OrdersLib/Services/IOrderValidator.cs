// Copyright © 2026 Amazon.com and Affiliates. Licensed under MIT-0.

using OrdersApi.Models;

namespace OrdersApi.Services;

public interface IOrderValidator
{
    (bool IsValid, string? Error) Validate(OrderRequest request);
}
