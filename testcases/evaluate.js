const fs = require('fs');
const path = require('path');

// Path to latest summary file (or passed via argument)
const summaryFile = process.argv[2];

if (!summaryFile) {
    console.error("Please provide path to summary.json. Example:");
    console.error("node evaluate.js reports/summary_20260820_115713.json");
    process.exit(1);
}

const summaryPath = path.resolve(summaryFile);

if (!fs.existsSync(summaryPath)) {
    console.error("File not found: " + summaryPath);
    process.exit(1);
}

// Read and parse summary JSON
let data;
try {
    data = JSON.parse(fs.readFileSync(summaryPath, 'utf8'));
} catch (e) {
    console.error("Error reading JSON file: " + e.message);
    process.exit(1);
}

let passed = 0;
let total = data.length;

console.log("==================================================");
console.log("          BFCL BENCHMARK EVALUATION RESULTS       ");
console.log("==================================================");

data.forEach((item, index) => {
    console.log(`\n▶ Test #${index + 1}: ${item.id}`);
    
    const extractedCall = item.extracted_call;
    let isSuccess = false;

    // Basic analysis: check if LLM generated correctly formatted function call
    if (extractedCall && typeof extractedCall === 'object' && Object.keys(extractedCall).length > 0) {
        if (extractedCall.name && extractedCall.arguments) {
            console.log(`  ✓ Function name: ${extractedCall.name}`);
            console.log(`  ✓ Arguments:`, JSON.stringify(extractedCall.arguments));
            // Mark passed if LLM produced valid JSON with name and arguments.
            // In practice will map with 'possible_answer' from BFCL.
            isSuccess = true;
            passed++;
        } else {
            console.log(`  ✗ Object present but missing 'name' or 'arguments'.`);
        }
    } else {
        console.log(`  ✗ LLM did not output valid JSON object (or regex failed to extract).`);
    }

    if (!isSuccess) {
        console.log(`  ! Raw output:\n${item.raw_output}`);
    }
});

console.log("\n==================================================");
console.log(`Result: ${passed} / ${total} tests PASSED (${((passed/total)*100).toFixed(2)}%)`);
console.log("==================================================");
