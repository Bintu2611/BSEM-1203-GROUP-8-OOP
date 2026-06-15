-- ============================================================================
-- CLINIC SERVICE API DATABASE (POSTGRESQL) - COMPATIBLE RUNTIME SYSTEM
-- ============================================================================

-- 1. CLEANUP EXISTING STRUCTURES
DROP VIEW IF EXISTS vw_patient_records CASCADE;
DROP VIEW IF EXISTS vw_appointments CASCADE;
DROP VIEW IF EXISTS vw_doctor_schedule CASCADE;
DROP VIEW IF EXISTS vw_billing_information CASCADE;
DROP VIEW IF EXISTS vw_prescriptions CASCADE;
DROP VIEW IF EXISTS vw_medicine_inventory CASCADE;

DROP TABLE IF EXISTS audit_logs CASCADE;
DROP TABLE IF EXISTS bills CASCADE;
DROP TABLE IF EXISTS lab_tests CASCADE;
DROP TABLE IF EXISTS prescriptions CASCADE;
DROP TABLE IF EXISTS medicines CASCADE;
DROP TABLE IF EXISTS appointments CASCADE;
DROP TABLE IF EXISTS doctors CASCADE;
DROP TABLE IF EXISTS users CASCADE;
DROP TABLE IF EXISTS roles CASCADE;
DROP TABLE IF EXISTS patients CASCADE;

-- 2. CORE TABLES CREATION
CREATE TABLE roles (
    id SERIAL PRIMARY KEY,
    role_name VARCHAR(50) UNIQUE NOT NULL
);

CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    user_code VARCHAR(20) UNIQUE NOT NULL,
    full_name VARCHAR(150) NOT NULL,
    email VARCHAR(150) UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    role_id INT NOT NULL REFERENCES roles(id) ON DELETE RESTRICT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE doctors (
    id SERIAL PRIMARY KEY,
    user_id INT UNIQUE REFERENCES users(id) ON DELETE CASCADE,
    specialization VARCHAR(100),
    license_number VARCHAR(100) UNIQUE,
    phone VARCHAR(20)
);

CREATE TABLE patients ( 
    id SERIAL PRIMARY KEY,
    patient_code VARCHAR(20) UNIQUE,
    first_name VARCHAR(100) NOT NULL,
    last_name VARCHAR(100) NOT NULL,
    gender VARCHAR(20),
    date_of_birth DATE,
    phone VARCHAR(20),
    address TEXT,
    email VARCHAR(150),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE appointments (
    id SERIAL PRIMARY KEY,
    patient_id INT REFERENCES patients(id) ON DELETE CASCADE,
    doctor_id INT REFERENCES doctors(id) ON DELETE CASCADE,
    appointment_date TIMESTAMP NOT NULL,
    status VARCHAR(50) DEFAULT 'Scheduled',
    notes TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE medicines (
    id SERIAL PRIMARY KEY,
    medicine_name VARCHAR(150) NOT NULL,
    description TEXT,
    stock_quantity INT DEFAULT 0,
    unit_price NUMERIC(10,2) NOT NULL,
    expiry_date DATE
);

CREATE TABLE prescriptions (
    id SERIAL PRIMARY KEY,
    patient_id INT REFERENCES patients(id) ON DELETE CASCADE,
    doctor_id INT REFERENCES doctors(id) ON DELETE CASCADE,
    medicine_id INT REFERENCES medicines(id) ON DELETE RESTRICT,
    quantity INT NOT NULL CHECK (quantity > 0),
    dosage TEXT,
    prescribed_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE lab_tests (
    id SERIAL PRIMARY KEY,
    patient_id INT REFERENCES patients(id) ON DELETE CASCADE,
    technician_id INT REFERENCES users(id) ON DELETE RESTRICT,
    test_name VARCHAR(150) NOT NULL,
    result TEXT,
    test_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE bills (
    id SERIAL PRIMARY KEY,
    patient_id INT REFERENCES patients(id) ON DELETE CASCADE,
    amount NUMERIC(10,2) NOT NULL CHECK (amount >= 0),
    status VARCHAR(50) DEFAULT 'Pending',
    description VARCHAR(255) DEFAULT 'Medical Service Charge',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE audit_logs (
    id SERIAL PRIMARY KEY,
    table_name VARCHAR(100) NOT NULL,
    action VARCHAR(20) NOT NULL,
    record_id INT NOT NULL,
    changed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);









SELECT id, email, password_hash, role_id FROM users;


SELECT id, email, password_hash, role_id FROM users WHERE email = 'admin@clinic.com';


UPDATE users SET password_hash = '12345' WHERE email = 'admin@clinic.com';


-- Clear old tables to prevent conflicts
TRUNCATE TABLE users CASCADE;
TRUNCATE TABLE roles CASCADE;

-- Re-insert the core roles
INSERT INTO roles (id, role_name) VALUES 
(1, 'Administrator'), (2, 'Doctor'), (3, 'Nurse'), (4, 'Pharmacist'), (5, 'Receptionist');
SELECT setval('roles_id_seq', 5);

-- Insert a fresh, simple Admin account
INSERT INTO users (id, user_code, full_name, email, password_hash, role_id) VALUES
(1, 'ADM-001', 'System Admin', 'admin@clinic.com', '12345', 1);
SELECT setval('users_id_seq', 1);





-- 3. PROCEDURAL FUNCTIONS & TRIGGERS CONFIGURATION
CREATE OR REPLACE FUNCTION generate_patient_code()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.patient_code IS NULL THEN
        NEW.patient_code := 'PAT-' || LPAD(nextval('patients_id_seq')::TEXT, 5, '0');
    END IF;
    return NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_generate_patient_code
BEFORE INSERT ON patients
FOR EACH ROW EXECUTE FUNCTION generate_patient_code();

CREATE OR REPLACE FUNCTION update_appointment_status()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.appointment_date < CURRENT_TIMESTAMP THEN
        NEW.status := 'Completed';
    ELSE
        NEW.status := COALESCE(NEW.status, 'Scheduled');
    END IF;
    return NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_update_appointment_status
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW EXECUTE FUNCTION update_appointment_status();

CREATE OR REPLACE FUNCTION reduce_medicine_stock()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE medicines
    SET stock_quantity = stock_quantity - NEW.quantity
    WHERE id = NEW.medicine_id;
    return NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_reduce_medicine_stock
AFTER INSERT ON prescriptions
FOR EACH ROW EXECUTE FUNCTION reduce_medicine_stock();

CREATE OR REPLACE FUNCTION create_bill()
RETURNS TRIGGER AS $$
DECLARE
    medicine_cost NUMERIC(10,2);
    med_name VARCHAR(150);
BEGIN
    SELECT unit_price, medicine_name INTO medicine_cost, med_name
    FROM medicines WHERE id = NEW.medicine_id;

    INSERT INTO bills(patient_id, amount, description, status)
    VALUES (NEW.patient_id, (medicine_cost * NEW.quantity), 'Prescription Charge: ' || med_name, 'Pending');
    return NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_create_bill
AFTER INSERT ON prescriptions
FOR EACH ROW EXECUTE FUNCTION create_bill();

CREATE OR REPLACE FUNCTION audit_trigger_function()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO audit_logs (table_name, action, record_id)
    VALUES (TG_TABLE_NAME, TG_OP, COALESCE(NEW.id, OLD.id));
    return COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_audit_patients AFTER INSERT OR UPDATE OR DELETE ON patients FOR EACH ROW EXECUTE FUNCTION audit_trigger_function();
CREATE TRIGGER trg_audit_appointments AFTER INSERT OR UPDATE OR DELETE ON appointments FOR EACH ROW EXECUTE FUNCTION audit_trigger_function();
CREATE TRIGGER trg_audit_prescriptions AFTER INSERT OR UPDATE OR DELETE ON prescriptions FOR EACH ROW EXECUTE FUNCTION audit_trigger_function();

-- 4. BUSINESS INTEL SYSTEM VIEWS
CREATE VIEW vw_patient_records AS SELECT patient_code, first_name, last_name, gender, date_of_birth, phone, email FROM patients;
CREATE VIEW vw_appointments AS SELECT a.id, p.patient_code, p.first_name || ' ' || p.last_name AS patient_name, d.id AS doctor_id, a.appointment_date, a.status FROM appointments a JOIN patients p ON a.patient_id = p.id JOIN doctors d ON a.doctor_id = d.id;
CREATE VIEW vw_doctor_schedule AS SELECT d.id, d.specialization, a.appointment_date, a.status FROM doctors d LEFT JOIN appointments a ON d.id = a.doctor_id;
CREATE VIEW vw_billing_information AS SELECT b.id, p.patient_code, p.first_name, p.last_name, b.amount, b.description, b.status, b.created_at FROM bills b JOIN patients p ON b.patient_id = p.id;
CREATE VIEW vw_prescriptions AS SELECT pr.id, p.patient_code, m.medicine_name, pr.quantity, pr.dosage, pr.prescribed_date FROM prescriptions pr JOIN patients p ON pr.patient_id = p.id JOIN medicines m ON pr.medicine_id = m.id;
CREATE VIEW vw_medicine_inventory AS SELECT medicine_name, stock_quantity, unit_price, expiry_date FROM medicines;

-- 5. SEED DATA POPULATION
INSERT INTO roles (id, role_name) VALUES (1, 'Administrator'), (2, 'Doctor'), (3, 'Nurse'), (4, 'Pharmacist'), (5, 'Receptionist'), (6, 'Lab Technician'), (7, 'Patient'), (8, 'Employee');
SELECT setval('roles_id_seq', 8);

INSERT INTO users (id, user_code, full_name, email, password_hash, role_id) VALUES
(1, 'ADM-001', 'John Kamara', 'admin@clinic.com', 'hashed_password_1', 1),
(2, 'DOC-001', 'Dr. Sarah Bangura', 'sarah@clinic.com', 'hashed_password_2', 2),
(3, 'DOC-002', 'Dr. Ibrahim Conteh', 'ibrahim@clinic.com', 'hashed_password_3', 2),
(4, 'DOC-003', 'Dr. Mariama Sesay', 'mariama@clinic.com', 'hashed_password_4', 2),
(5, 'NUR-001', 'Mary Sesay', 'mary@clinic.com', 'hashed_password_5', 3),
(6, 'PHA-001', 'David Conteh', 'david@clinic.com', 'hashed_password_6', 4),
(7, 'REC-001', 'Aminata Kallon', 'aminata@clinic.com', 'hashed_password_7', 5),
(8, 'LAB-001', 'Mohamed Koroma', 'mohamed@clinic.com', 'hashed_password_8', 6),
(9, 'PAT-001', 'Ali Kamara', 'ali@gmail.com', 'hashed_password_9', 7),
(10, 'PAT-002', 'Fatmata Sesay', 'fatmata@gmail.com', 'hashed_password_10', 7),
(11, 'PAT-003', 'Abdul Bangura', 'abdul@gmail.com', 'hashed_password_11', 7),
(12, 'EMP-001', 'Hawa Koroma', 'hawa@clinic.com', 'hashed_password_12', 8);
SELECT setval('users_id_seq', 12);

INSERT INTO doctors (id, user_id, specialization, license_number, phone) VALUES
(1, 2, 'General Medicine', 'DOC-LIC-001', '076555111'),
(2, 3, 'Cardiology', 'DOC-LIC-002', '076555222'),
(3, 4, 'Pediatrics', 'DOC-LIC-003', '076555333');
SELECT setval('doctors_id_seq', 3);

INSERT INTO patients (id, patient_code, first_name, last_name, gender, date_of_birth, phone, address, email) VALUES
(1, 'PAT-00001', 'Ali', 'Kamara', 'Male', '1998-05-10', '076123456', 'Sesay Drive, Freetown', 'ali@gmail.com'),
(2, 'PAT-00002', 'Fatmata', 'Sesay', 'Female', '2000-08-15', '078654321', 'Wilkinson Road, Freetown', 'fatmata@gmail.com'),
(3, 'PAT-00003', 'Abdul', 'Bangura', 'Male', '1997-04-22', '077112233', 'Femi Turnner, Freetown', 'abdul@gmail.com'),
(4, 'PAT-00004', 'Mariatu', 'Koroma', 'Female', '1995-11-18', '076987654', 'frontier Road, Makeni', 'mariatu@gmail.com'),
(5, 'PAT-00005', 'Mohamed', 'Kallon', 'Male', '1992-03-07', '075445566', 'Liverpool Street Freetown', 'mohamed@gmail.com'),
(6, 'PAT-00006', 'Hawa', 'Conteh', 'Female', '1999-09-30', '078112244', 'Waterloo, Freetown', 'hawa@gmail.com'),
(7, 'PAT-00007', 'Ibrahim', 'Turay', 'Male', '1988-12-12', '077998877', 'Lumley Beach, Freetown', 'ibrahim@gmail.com'),
(8, 'PAT-00008', 'Aminata', 'Kamara', 'Female', '2001-06-25', '076556677', 'Angola, freetown', 'aminata@gmail.com'),
(9, 'PAT-00009', 'Sorie', 'Bangura', 'Male', '1994-08-14', '078334455', 'Clock Tower, Kabala', 'sorie@gmail.com'),
(10, 'PAT-00010', 'Kadijatu', 'Sesay', 'Female', '1996-01-19', '075667788', 'Adokia, Freetown', 'kadijatu@gmail.com');
SELECT setval('patients_id_seq', 10);

INSERT INTO medicines (id, medicine_name, description, stock_quantity, unit_price, expiry_date) VALUES
(1, 'Paracetamol', 'Pain relief and fever reducer', 500, 5.00, '2027-12-31'),
(2, 'Amoxicillin', 'Antibiotic for infections', 300, 12.50, '2027-10-30'),
(3, 'Ibuprofen', 'Anti-inflammatory painkiller', 400, 8.00, '2027-08-20'),
(4, 'Vitamin C', 'Immune system support', 600, 3.50, '2028-01-15'),
(5, 'Metformin', 'Used for diabetes control', 200, 15.00, '2027-09-10'),
(6, 'Cough Syrup', 'Relieves cough and sore throat', 150, 7.25, '2026-12-01'),
(7, 'Antacid', 'Treats heartburn and indigestion', 350, 4.00, '2027-06-18'),
(8, 'Antihistamine', 'Allergy relief medication', 250, 6.75, '2027-11-05'),
(9, 'ORS', 'Oral rehydration solution', 800, 2.00, '2028-03-22'),
(10, 'Aspirin', 'Pain relief and blood thinner', 450, 5.50, '2027-05-30');
SELECT setval('medicines_id_seq', 10);

INSERT INTO appointments (patient_id, doctor_id, appointment_date, notes) VALUES
(1, 1, '2026-06-10 09:00:00', 'General checkup'),
(2, 2, '2026-06-10 11:00:00', 'Heart consultation'),
(3, 3, '2026-06-11 14:00:00', 'Child health review'),
(4, 1, '2026-06-12 10:30:00', 'Fever and headache'),
(5, 2, '2026-06-12 12:00:00', 'Blood pressure check'),
(6, 3, '2026-06-13 09:30:00', 'Routine checkup'),
(7, 1, '2026-06-13 11:00:00', 'Malaria symptoms'),
(8, 2, '2026-06-14 13:00:00', 'Diabetes follow-up'),
(9, 3, '2026-06-14 15:00:00', 'Vaccination review'),
(10, 1, '2026-06-15 08:30:00', 'General consultation');

INSERT INTO lab_tests (patient_id, technician_id, test_name, result) VALUES
(1, 8, 'Malaria Test', 'Negative'),
(2, 8, 'Blood Sugar Test', 'Normal'),
(3, 8, 'Typhoid Test', 'Positive'),
(4, 8, 'HIV Test', 'Negative'),
(5, 8, 'Cholesterol Test', 'High'),
(6, 8, 'Urine Test', 'Normal'),
(7, 8, 'COVID-19 Test', 'Negative'),
(8, 8, 'Blood Group Test', 'O+'),
(9, 8, 'Hepatitis B Test', 'Negative'),
(10, 8, 'Widal Test', 'Positive');

INSERT INTO bills (patient_id, amount, status, description) VALUES
(1, 50.00, 'Paid', 'Consultation Fee'),
(2, 175.00, 'Pending', 'Laboratory Workup'),
(3, 70.00, 'Paid', 'General Outpatient Care'),
(4, 40.00, 'Paid', 'Consultation Fee'),
(5, 120.00, 'Pending', 'Specialist Review'),
(6, 65.00, 'Paid', 'General Outpatient Care'),
(7, 90.00, 'Pending', 'Laboratory Workup'),
(8, 55.00, 'Paid', 'Consultation Fee'),
(9, 110.00, 'Pending', 'Specialist Review'),
(10, 80.00, 'Paid', 'General Outpatient Care');

INSERT INTO prescriptions (patient_id, doctor_id, medicine_id, quantity, dosage) VALUES
(1, 1, 1, 10, 'Take 2 tablets daily after meals'),
(2, 2, 2, 14, 'Take 1 capsule twice daily'),
(3, 3, 3, 20, 'Take 1 tablet daily in the morning'),
(4, 1, 2, 7,  'Take 1 capsule daily before bed'),
(5, 2, 1, 12, 'Take 2 tablets every 8 hours'),
(6, 3, 3, 15, 'Take 1 tablet daily with water'),
(7, 1, 1, 8,  'Take 2 tablets after breakfast'),
(8, 2, 2, 10, 'Take 1 capsule every 12 hours'),
(9, 3, 3, 5,  'Take 1 tablet when needed for pain'),
(10, 1, 1, 6, 'Take 2 tablets daily after meals');

-- 6. PRIVILEGES CONFIGURATION
ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
GRANT SELECT, INSERT, UPDATE ON TABLE patients, appointments, prescriptions, medicines, lab_tests, bills TO PUBLIC;
REVOKE DELETE ON TABLE patients, appointments, prescriptions, medicines, lab_tests, bills FROM PUBLIC;