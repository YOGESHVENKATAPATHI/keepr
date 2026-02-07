require('dotenv').config();
const nodemailer = require('nodemailer');
const { OAuth2Client } = require('google-auth-library');
const googleClient = new OAuth2Client(process.env.GOOGLE_CLIENT_ID || '');

const transporter = nodemailer.createTransport({
    service: 'gmail',
    auth: {
        user: process.env.EMAIL_USER,
        pass: process.env.EMAIL_PASS
    }
});

// Verify transporter at startup to catch auth issues early
transporter.verify((err, success) => {
    if (err) {
        console.error('[Auth] SMTP transporter verification failed:', err.message || err);
        console.error('[Auth] Common fixes: enable 2FA and use an App Password; check EMAIL_USER/EMAIL_PASS in .env; workspace admins may block SMTP.');
    } else {
        console.log('[Auth] SMTP transporter verified OK');
    }
});


const otpStore = new Map(); // Store OTPs in memory for demo (email -> otp)

function generateOTP() {
    return Math.floor(100000 + Math.random() * 900000).toString();
}

async function sendOTP(email) {
    const otp = generateOTP();
    otpStore.set(email, otp);

    const mailOptions = {
        from: 'keeprofficialservices@gmail.com',
        to: email,
        subject: 'Your Keepr Login OTP',
        text: `Your OTP is: ${otp}`
    };

    try {
        await transporter.sendMail(mailOptions);
        console.log(`OTP sent to ${email}`);
        // For debug only: log OTP when DEBUG_OTP env var is set
        if (process.env.DEBUG_OTP === 'true') console.log(`[Auth][DEBUG] OTP for ${email}: ${otp}`);
        return true;
    } catch (error) {
        console.error('Error sending email:', error);
        return false;
    }
}

function verifyOTP(email, otp) {
    console.log(`[Auth] verifyOTP attempt for ${email} (otpLength=${otp ? otp.length : 0})`);
    if (otpStore.has(email) && otpStore.get(email) === otp) {
        otpStore.delete(email); // Invalidate after use
        console.log(`[Auth] verifyOTP success for ${email}`);
        return true;
    }
    console.warn(`[Auth] verifyOTP failed for ${email}`);
    return false;
}

async function verifyTransport() {
    return new Promise((resolve, reject) => {
        transporter.verify((err, success) => {
            if (err) return reject(err);
            resolve(success);
        });
    });
}

// Google id_token verification helper
async function verifyGoogleIdToken(idToken) {
    if (!idToken) return { ok: false, error: 'idToken required' };
    try {
        const ticket = await googleClient.verifyIdToken({ idToken, audience: process.env.GOOGLE_CLIENT_ID });
        const payload = ticket.getPayload();
        // Contains: email, email_verified, sub (google id), name, picture
        return { ok: true, payload };
    } catch (e) {
        console.error('[Auth] verifyGoogleIdToken failed:', e.message || e);
        return { ok: false, error: e.message || 'Invalid token' };
    }
}

// Send PIN reset email (resetToken should be an opaque token generated server-side)
async function sendPinResetEmail(email, resetToken, resetUrlBase) {
    // resetUrlBase example: https://yourapp.com/pin-reset?token=
    const resetUrl = `${resetUrlBase}${encodeURIComponent(resetToken)}`;
    const mailOptions = {
        from: 'keeprofficialservices@gmail.com',
        to: email,
        subject: 'Reset your Keepr PIN',
        text: `You requested a PIN reset. Click the link to reset your 6-digit PIN: ${resetUrl}\n\nIf you did not request this, ignore this email.`
    };

    try {
        await transporter.sendMail(mailOptions);
        console.log(`PIN reset email sent to ${email}`);
        return true;
    } catch (error) {
        console.error('Error sending PIN reset email:', error);
        return false;
    }
}

module.exports = {
    sendOTP,
    verifyOTP,
    verifyTransport,
    verifyGoogleIdToken,
    sendPinResetEmail
};
