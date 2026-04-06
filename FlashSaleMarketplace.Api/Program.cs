using Microsoft.EntityFrameworkCore;
using MongoDB.Driver;

var builder = WebApplication.CreateBuilder(args);

// ==========================================
// 1. CẤU HÌNH SQL SERVER (Cho Thành viên 1)
// ==========================================
var sqlConnectionString = builder.Configuration.GetConnectionString("SqlServerConnection");
// TODO (Thành viên 1): Khi tạo class AppDbContext ở Tuần 2, hãy bỏ comment dòng bên dưới
// builder.Services.AddDbContext<AppDbContext>(options => options.UseSqlServer(sqlConnectionString));

// ==========================================
// 2. CẤU HÌNH MONGODB (Cho Thành viên 2)
// ==========================================
var mongoConnectionString = builder.Configuration.GetConnectionString("MongoDbConnection");
var mongoDbName = builder.Configuration.GetSection("MongoDbSettings:DatabaseName").Value;

builder.Services.AddSingleton<IMongoClient>(new MongoClient(mongoConnectionString));
builder.Services.AddScoped(sp => 
{
    var client = sp.GetRequiredService<IMongoClient>();
    return client.GetDatabase(mongoDbName);
});

// ==========================================
// 3. CẤU HÌNH API & SWAGGER
// ==========================================
builder.Services.AddControllers();
builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen();

var app = builder.ApplicationBuilder.Build();

if (app.Environment.IsDevelopment())
{
    app.UseSwagger();
    app.UseSwaggerUI();
}

app.UseDefaultFiles();
app.UseStaticFiles();

app.UseHttpsRedirection();
app.UseAuthorization();
app.MapControllers();

app.Run();