using Microsoft.AspNetCore.RateLimiting;
using System.Threading.RateLimiting;
using Microsoft.EntityFrameworkCore;
using MongoDB.Driver;
using StackExchange.Redis; // THÊM DÒNG NÀY
using FlashSaleMarketplace.Api.Services; 

var builder = WebApplication.CreateBuilder(args);

// ==========================================
// 1. CẤU HÌNH SQL SERVER
// ==========================================
var sqlConnectionString = builder.Configuration.GetConnectionString("SqlServerConnection");

// ==========================================
// 2. CẤU HÌNH MONGODB
// ==========================================
var mongoConnectionString = builder.Configuration.GetConnectionString("MongoDbConnection");
var mongoDbName = builder.Configuration.GetSection("MongoDbSettings:DatabaseName").Value;

builder.Services.AddSingleton<IMongoClient>(new MongoClient(mongoConnectionString));
builder.Services.AddScoped<IMongoDatabase>(sp => 
{
    var client = sp.GetRequiredService<IMongoClient>();
    return client.GetDatabase(mongoDbName);
});

// FIX 5: TTL Index — Tự xóa cart không hoạt động sau 7 ngày
using (var scope = new ServiceCollection()
    .BuildServiceProvider()
    .CreateScope())
{
    try
    {
        var mongoClient = new MongoClient(mongoConnectionString);
        var mongoDatabase = mongoClient.GetDatabase(mongoDbName);
        var cartCollection = mongoDatabase.GetCollection<MongoDB.Bson.BsonDocument>("Carts");

        var ttlIndexKey = Builders<MongoDB.Bson.BsonDocument>.IndexKeys.Ascending("lastModified");
        var ttlIndexOptions = new CreateIndexOptions
        {
            ExpireAfter = TimeSpan.FromDays(7),
            Name = "TTL_lastModified_7days"
        };

        cartCollection.Indexes.CreateOneAsync(
            new CreateIndexModel<MongoDB.Bson.BsonDocument>(ttlIndexKey, ttlIndexOptions)
        ).Wait();

        Console.ForegroundColor = ConsoleColor.Green;
        Console.WriteLine("[MONGODB] TTL Index đã được tạo: Cart sẽ tự xóa sau 7 ngày không hoạt động");
        Console.ResetColor();
    }
    catch (Exception ex)
    {
        Console.ForegroundColor = ConsoleColor.Yellow;
        Console.WriteLine($"[MONGODB WARNING] TTL Index setup: {ex.Message}");
        Console.ResetColor();
    }
}

builder.Services.AddScoped<CartService>();

// ==========================================
// 2.5. CẤU HÌNH REDIS (Nâng cấp Phase 1 & 2)
// ==========================================
var redisConnectionString = builder.Configuration.GetConnectionString("RedisConnection");
// Dùng Singleton để dùng chung 1 Multiplexer cho toàn bộ ứng dụng (Tối ưu kết nối mạng)
builder.Services.AddSingleton<IConnectionMultiplexer>(ConnectionMultiplexer.Connect(redisConnectionString!));


// ==========================================
// 3. CẤU HÌNH API & SWAGGER
// ==========================================
builder.Services.AddControllers();
builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen();
// [THÊM MỚI] Đăng ký RabbitMQ Producer
builder.Services.AddSingleton<FlashSaleMarketplace.Api.Messaging.RabbitMqProducer>();

// [THÊM MỚI] Đăng ký Công nhân chạy ngầm hút Queue
builder.Services.AddHostedService<FlashSaleMarketplace.Api.Workers.OrderProcessingWorker>();

// ==========================================
// 4. CẤU HÌNH RATE LIMITING (PHASE 4 - CHỐNG BOT THEO IP + JWT UserID)
// ==========================================
builder.Services.AddRateLimiter(options =>
{
    options.RejectionStatusCode = 429;
    
    // FIX 3: Ưu tiên UserID từ JWT kết hợp IP để partition chính xác
    options.AddPolicy("FlashSaleLimit", httpContext =>
    {
        // Thứ 1: Ưu tiên đọc UserID từ JWT (nếu user đã đăng nhập)
        var userIdClaim = httpContext.User?
            .FindFirst(System.Security.Claims.ClaimTypes.NameIdentifier)?.Value;

        // Thứ 2: Nếu không có JWT, dùng IP
        var clientIp = httpContext.Request.Headers["X-Real-IP"].ToString();
        if (string.IsNullOrEmpty(clientIp))
        {
            clientIp = httpContext.Connection.RemoteIpAddress?.ToString() ?? "unknown";
        }

        // Partition Key: Ưu tiên UserID (1 user = 1 partition dù đổi IP)
        // Còn lại: IP-based (anonymous users)
        var partitionKey = string.IsNullOrEmpty(userIdClaim)
            ? $"ip:{clientIp}"
            : $"user:{userIdClaim}";

        return RateLimitPartition.GetFixedWindowLimiter(
            partitionKey: partitionKey, 
            factory: partition => new FixedWindowRateLimiterOptions
            {
                PermitLimit = 5, // Mỗi user/IP khác nhau được phép gọi 5 lần / giây
                Window = TimeSpan.FromSeconds(1),
                QueueProcessingOrder = QueueProcessingOrder.OldestFirst,
                QueueLimit = 0
            });
    });
});

builder.Services.AddHttpClient();

var app = builder.Build();



if (app.Environment.IsDevelopment())
{
    app.UseSwagger();
    app.UseSwaggerUI();
}

app.UseDefaultFiles();
app.UseStaticFiles();

// app.UseHttpsRedirection();
app.UseAuthorization();
app.UseRateLimiter();
app.MapControllers();

app.Run();