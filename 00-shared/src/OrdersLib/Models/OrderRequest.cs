// Copyright © 2026 Amazon.com and Affiliates. Licensed under MIT-0.

namespace OrdersApi.Models;

public record OrderRequest(
    string CustomerId,
    string ProductId,
    int Quantity);
