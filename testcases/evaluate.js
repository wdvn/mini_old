const fs = require('fs');
const path = require('path');

// Đường dẫn file summary gần nhất (hoặc được truyền qua argument)
const summaryFile = process.argv[2];

if (!summaryFile) {
    console.error("Vui lòng truyền đường dẫn file summary.json. Ví dụ:");
    console.error("node evaluate.js reports/summary_20260820_115713.json");
    process.exit(1);
}

const summaryPath = path.resolve(summaryFile);

if (!fs.existsSync(summaryPath)) {
    console.error("Không tìm thấy file: " + summaryPath);
    process.exit(1);
}

// Đọc và parse summary JSON
let data;
try {
    data = JSON.parse(fs.readFileSync(summaryPath, 'utf8'));
} catch (e) {
    console.error("Lỗi khi đọc file JSON: " + e.message);
    process.exit(1);
}

let passed = 0;
let total = data.length;

console.log("==================================================");
console.log("          KẾT QUẢ ĐÁNH GIÁ BFCL BENCHMARK         ");
console.log("==================================================");

data.forEach((item, index) => {
    console.log(`\n▶ Test #${index + 1}: ${item.id}`);
    
    const extractedCall = item.extracted_call;
    let isSuccess = false;

    // Phân tích cơ bản: Kiểm tra LLM có tạo được hàm gọi đúng định dạng không
    if (extractedCall && typeof extractedCall === 'object' && Object.keys(extractedCall).length > 0) {
        if (extractedCall.name && extractedCall.arguments) {
            console.log(`  ✓ Có tên hàm: ${extractedCall.name}`);
            console.log(`  ✓ Danh sách tham số (arguments):`, JSON.stringify(extractedCall.arguments));
            // Đánh dấu passed nếu LLM xuất được JSON hợp lệ có name và arguments.
            // Trong thực tế sẽ map với 'possible_answer' của BFCL.
            isSuccess = true;
            passed++;
        } else {
            console.log(`  ✗ Có object nhưng thiếu 'name' hoặc 'arguments'.`);
        }
    } else {
        console.log(`  ✗ LLM không xuất ra object JSON hợp lệ (hoặc regex không lấy được).`);
    }

    if (!isSuccess) {
        console.log(`  ! Output nguyên bản:\n${item.raw_output}`);
    }
});

console.log("\n==================================================");
console.log(`Kết quả: ${passed} / ${total} tests PASSED (${((passed/total)*100).toFixed(2)}%)`);
console.log("==================================================");
