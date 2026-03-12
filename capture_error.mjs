import puppeteer from 'puppeteer';

(async () => {
    const browser = await puppeteer.launch();
    const page = await browser.newPage();

    page.on('console', msg => {
        if (msg.type() === 'error') {
            console.error(`Browser Error:`, msg.text());
        }
    });

    page.on('pageerror', err => {
        console.error(`Page Exception:`, err.toString());
    });

    try {
        await page.goto('http://localhost:5174/admin', { waitUntil: 'networkidle2', timeout: 15000 });
        console.log('Page loaded successfully');
    } catch (e) {
        console.error('Navigation error:', e.message);
    }
    
    await browser.close();
})();
