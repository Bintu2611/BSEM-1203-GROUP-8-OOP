import os
import time
import random
from datetime import datetime, timedelta, timezone
from typing import AsyncGenerator, List, Dict, Any, Optional
from fastapi import FastAPI, Depends, HTTPException, status, APIRouter, Request, Response
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import OAuth2PasswordBearer, OAuth2PasswordRequestForm
from fastapi.responses import JSONResponse, HTMLResponse
from pydantic import BaseModel, EmailStr, Field, ConfigDict
from pydantic_settings import BaseSettings
from jose import jwt, JWTError
from sqlalchemy import text
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker, AsyncSession

# ==============================================================================
# TERMINAL COLOR COLORIZATION SYSTEM (Aesthetics)
# ==============================================================================
CLR_CYAN = "\033[96m"
CLR_GREEN = "\033[92m"
CLR_YELLOW = "\033[93m"
CLR_RED = "\033[91m"
CLR_RESET = "\033[0m"

def log_terminal(tag: str, color: str, message: str):
    print(f"{color}[{tag.upper()}] {message}{CLR_RESET}")

# ==============================================================================
# 1. APPLICATION SETTINGS & CONFIGURATION SYSTEM
# ==============================================================================
class Settings(BaseSettings):
    DATABASE_URL: str = "postgresql+asyncpg://postgres:12345@localhost:5432/CLINIC_database"
    JWT_SECRET: str = "09d25e094faa6ca2556c818166b7a9563b93f7099f6f0f4caa6cf63b88e8d3e7"
    ALGORITHM: str = "HS256"
    ACCESS_TOKEN_EXPIRE_MINUTES: int = 480

settings = Settings()

# ==============================================================================
# 2. CRYPTOGRAPHY AND SECURITY CONSTANTS
# ==============================================================================
# FIXED: Points cleanly to the absolute route path layout to prevent dependency injection failure
oauth2_scheme = OAuth2PasswordBearer(tokenUrl="api/v1/auth/login")

def create_access_token(data: Dict[str, Any]) -> str:
    to_encode = data.copy()
    expire = datetime.now(timezone.utc) + timedelta(minutes=settings.ACCESS_TOKEN_EXPIRE_MINUTES)
    to_encode.update({"exp": expire})
    return jwt.encode(to_encode, settings.JWT_SECRET, algorithm=settings.ALGORITHM)

# ==============================================================================
# 3. ASYNCHRONOUS DATABASE LAYER ENGINE CONNECTOR
# ==============================================================================
engine = create_async_engine(settings.DATABASE_URL, echo=False, future=True)
async_session_factory = async_sessionmaker(engine, expire_on_commit=False, class_=AsyncSession)

async def get_db_session() -> AsyncGenerator[AsyncSession, None]:
    async with async_session_factory() as session:
        try:
            yield session
        finally:
            await session.close()

# ==============================================================================
# 4. STRONG-TYPED VALIDATION DATA SCHEMAS (PYDANTIC V2)
# ==============================================================================
class Token(BaseModel):
    access_token: str
    token_type: str

class TokenData(BaseModel):
    user_id: int
    email: str
    role_id: int

class UserCreate(BaseModel):
    email: EmailStr = Field(..., description="Unique profile email registration key mapping string")
    password: str = Field(..., min_length=4, description="Raw non-encrypted matching credential context string")
    role_id: int = Field(..., ge=1, le=8, description="Target relational primary identification key role mapping")
    full_name: str = Field(default="New Clinical Staff Member", description="Default placeholder value to satisfy DB constraints")

class PrescriptionCreate(BaseModel):
    patient_id: int = Field(..., description="Valid relational key from patients table", examples=[1])
    doctor_id: int = Field(..., description="Valid relational key from doctors table", examples=[1])
    medicine_id: int = Field(..., description="Target pharmaceutical stock catalog key", examples=[1])
    quantity: int = Field(..., gt=0, description="Deduction batch count limit", examples=[10])
    dosage: str = Field(..., min_length=5, description="Clear therapeutic instructions", examples=["Take 1 every 8 hours"])

class BillingReportSchema(BaseModel):
    id: int
    patient_code: Optional[str] = None
    first_name: str
    last_name: str
    amount: float
    description: Optional[str] = None
    status: str
    created_at: datetime
    model_config = ConfigDict(from_attributes=True)

class AppointmentViewSchema(BaseModel):
    id: int
    patient_code: Optional[str] = None
    patient_name: str
    doctor_id: int
    appointment_date: datetime
    status: str
    model_config = ConfigDict(from_attributes=True)

class MedicineInventorySchema(BaseModel):
    medicine_name: str
    stock_quantity: int
    unit_price: float
    expiry_date: Optional[Any] = None
    model_config = ConfigDict(from_attributes=True)

class FinancialMetricsResponse(BaseModel):
    gross_revenue: float
    total_invoices_generated: int
    collected_revenue: float
    pending_receivables: float
    collection_efficiency_rate: str

# ==============================================================================
# 5. OAUTH2 AUTHORIZATION GUARDS AND ROLE-BASED CONTROLS (RBAC)
# ==============================================================================
async def get_current_user(token: str = Depends(oauth2_scheme)) -> TokenData:
    credentials_exception = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Could not validate credentials token authorization token.",
        headers={"WWW-Authenticate": "Bearer"},
    )
    try:
        payload = jwt.decode(token, settings.JWT_SECRET, algorithms=[settings.ALGORITHM])
        email: str = payload.get("sub")
        user_id: int = payload.get("id")
        role_id: int = payload.get("role_id")
        
        if email is None or user_id is None or role_id is None:
            raise credentials_exception
        return TokenData(user_id=user_id, email=email, role_id=role_id)
    except JWTError:
        raise credentials_exception

class RequireRole:
    def __init__(self, allowed_roles: List[int]):
        self.allowed_roles = allowed_roles

    def __call__(self, current_user: TokenData = Depends(get_current_user)) -> TokenData:
        if current_user.role_id not in self.allowed_roles:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="Access denied: Your account role tier does not permit this transaction action."
            )
        return current_user

# ==============================================================================
# 6. AUTHENTICATION & REGISTRATION ROUTER 
# ==============================================================================
auth_router = APIRouter(prefix="/auth", tags=["System Access Gate (OAuth2 / JWT)"])

@auth_router.post("/register", status_code=status.HTTP_201_CREATED)
async def register_new_clinic_user(
    payload: UserCreate,
    db: AsyncSession = Depends(get_db_session)
):
    dup_query = text("SELECT id FROM users WHERE email = :email")
    dup_result = await db.execute(dup_query, {"email": payload.email})
    if dup_result.fetchone():
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Registration Fault: An account matching that email address already exists."
        )

    try:
        prefix_map = {1: "ADM", 2: "DOC", 3: "NUR", 4: "PHA", 5: "REC", 6: "LAB", 7: "PAT", 8: "EMP"}
        prefix = prefix_map.get(payload.role_id, "USR")
        generated_code = f"{prefix}-{random.randint(100, 999)}"

        command = text("""
            INSERT INTO users (user_code, full_name, email, password_hash, role_id) 
            VALUES (:user_code, :full_name, :email, :password_hash, :role_id) RETURNING id;
        """)
        result = await db.execute(command, {
            "user_code": generated_code,
            "full_name": payload.full_name,
            "email": payload.email,
            "password_hash": payload.password, 
            "role_id": payload.role_id
        })
        await db.commit()
        return {"msg": "Registration sequence successful", "assigned_user_id": result.scalar()}
    except Exception as err:
        await db.rollback()
        raise HTTPException(status_code=500, detail=f"Database ingestion failure structural drop: {str(err)}")

@auth_router.post("/login", response_model=Token)
async def login_for_access_token(
    form_data: OAuth2PasswordRequestForm = Depends(),
    db: AsyncSession = Depends(get_db_session)
):
    query = text("SELECT id, email, password_hash, role_id FROM users WHERE email = :email")
    result = await db.execute(query, {"email": form_data.username})
    user = result.fetchone()

    if not user or form_data.password != user.password_hash:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Invalid email username or credential verification token verification pair."
        )

    # FIXED: Maps values via standard dictionary key/index lookups to resolve tuple unpacking bugs
    access_token = create_access_token(data={"sub": user[1], "id": user[0], "role_id": user[3]})
    return {"access_token": access_token, "token_type": "bearer"}

# ==============================================================================
# 7. CLINICAL OPERATIONS CONTROL ROUTER
# ==============================================================================
clinic_router = APIRouter(prefix="/clinic", tags=["Internal Medical Operations Control"])

@clinic_router.get("/billing", response_model=List[BillingReportSchema])
async def get_billing_information_records(
    limit: int = 50, offset: int = 0,
    db: AsyncSession = Depends(get_db_session),
    _user=Depends(RequireRole([1, 5]))
):
    query = text("SELECT * FROM vw_billing_information LIMIT :limit OFFSET :offset;")
    result = await db.execute(query, {"limit": limit, "offset": offset})
    return result.mappings().all() # FIXED: Changed from .fetchall() to support Pydantic conversion validation

@clinic_router.get("/appointments", response_model=List[AppointmentViewSchema])
async def get_clinic_appointments(
    limit: int = 50, offset: int = 0,
    db: AsyncSession = Depends(get_db_session),
    _user=Depends(RequireRole([1, 2, 3, 5]))
):
    query = text("SELECT * FROM vw_appointments LIMIT :limit OFFSET :offset;")
    result = await db.execute(query, {"limit": limit, "offset": offset})
    return result.mappings().all() # FIXED: Corrected mapping matrix formatting configurations

@clinic_router.get("/inventory", response_model=List[MedicineInventorySchema])
async def get_medicine_inventory_records(
    db: AsyncSession = Depends(get_db_session),
    _user=Depends(RequireRole([1, 4]))
):
    query = text("SELECT * FROM vw_medicine_inventory;")
    result = await db.execute(query)
    return result.mappings().all() # FIXED: Standardized view data mappings serialization hook up

@clinic_router.post("/prescriptions", status_code=status.HTTP_201_CREATED)
async def prescribe_medication(
    payload: PrescriptionCreate,
    db: AsyncSession = Depends(get_db_session),
    _doctor=Depends(RequireRole([2]))
):
    try:
        command = text("""
            INSERT INTO prescriptions (patient_id, doctor_id, medicine_id, quantity, dosage)
            VALUES (:patient_id, :doctor_id, :medicine_id, :quantity, :dosage) RETURNING id;
        """)
        result = await db.execute(command, {
            "patient_id": payload.patient_id,
            "doctor_id": payload.doctor_id,
            "medicine_id": payload.medicine_id,
            "quantity": payload.quantity,
            "dosage": payload.dosage
        })
        await db.commit()
        return {
            "msg": "Prescription record generated successfully.",
            "reference_id": result.scalar(),
            "database_triggers_fired": ["Medicine Stock Decremented Automatically", "Patient Invoice Generated"]
        }
    except Exception as err:
        await db.rollback()
        raise HTTPException(status_code=400, detail=f"Database operational error: {str(err)}")

@clinic_router.get("/analytics/financials", response_model=FinancialMetricsResponse)
async def get_clinic_financial_metrics(
    db: AsyncSession = Depends(get_db_session),
    _admin=Depends(RequireRole([1]))
):
    query = text("""
        SELECT 
            COALESCE(SUM(amount), 0.0) as gross, COUNT(id) as count,
            COALESCE(SUM(CASE WHEN status = 'Paid' THEN amount ELSE 0 END), 0.0) as paid,
            COALESCE(SUM(CASE WHEN status = 'Pending' THEN amount ELSE 0 END), 0.0) as pending
        FROM bills;
    """)
    result = await db.execute(query)
    metrics = result.fetchone()

    gross = float(metrics.gross)
    efficiency = f"{(float(metrics.paid) / gross * 100):.2f}%" if gross > 0 else "0.00%"

    return {
        "gross_revenue": gross,
        "total_invoices_generated": int(metrics.count),
        "collected_revenue": float(metrics.paid),
        "pending_receivables": float(metrics.pending),
        "collection_efficiency_rate": efficiency
    }

# ==============================================================================
# 8. APPLICATION BASE ARCHITECTURE INITIALIZATION & UI HOSTING
# ==============================================================================
app = FastAPI(
    title="CLINIC SERVICE API FOR SEARCHING LOCAL CLINIC",
    description="Asynchronous Microservice Control Interface with Native Database Triggers.",
    version="1.5.0",
    docs_url="/docs"
)

@app.get("/", response_class=HTMLResponse, tags=["GUI Gateway"])
async def serve_clinic_dashboard_gui():
    try:
        with open("index.html", "r", encoding="utf-8") as file:
            return HTMLResponse(content=file.read(), status_code=200)
    except FileNotFoundError:
        return HTMLResponse(content="<h2>Error: 'index.html' not found in project directory.</h2>", status_code=404)

@app.middleware("http")
async def add_performance_and_logging_headers(request: Request, call_next):
    start_time = time.perf_counter()
    response: Response = await call_next(request)
    process_time = time.perf_counter() - start_time
    response.headers["X-Process-Time"] = f"{process_time:.4f}s"
    log_terminal("info", CLR_CYAN, f"{request.method} -> {request.url.path} ({process_time:.4f}s) [{response.status_code}]")
    return response

@app.exception_handler(Exception)
async def global_systemic_exception_handler(request: Request, exc: Exception):
    log_terminal("error", CLR_RED, f"Critical Exception: {str(exc)}")
    return JSONResponse(status_code=500, content={"error": "Internal System Failure", "details": str(exc)})

# FIXED: Standardized middleware initialization constraints
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_credentials=True, allow_methods=["*"], allow_headers=["*"])
app.include_router(auth_router, prefix="/api/v1")
app.include_router(clinic_router, prefix="/api/v1")

@app.on_event("startup")
async def on_startup_banner():
    print(f"\n{CLR_GREEN}===================================================================={CLR_RESET}")
    log_terminal("success", CLR_GREEN, "CLINIC SERVICE API INTERACTIVE APP OPERATIONAL")
    log_terminal("info", CLR_CYAN, f"GUI Interface Panel Running At: http://127.0.0.1:8000/")
    print(f"{CLR_GREEN}====================================================================\n{CLR_RESET}")

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="127.0.0.1", port=8000, reload=True)