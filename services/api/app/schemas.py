from datetime import date, datetime
from typing import Generic, Literal, TypeVar
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field


class Strict(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


class IdentityClaim(Strict):
    enrollment_number: str = Field(min_length=1, max_length=32)


class OfferingCreate(Strict):
    course_id: UUID
    term_id: UUID
    class_group_id: UUID
    teacher_id: UUID | None = None


class JoinRequest(Strict):
    join_code: str = Field(min_length=1, max_length=40)


class Decision(Strict):
    status: Literal["active", "rejected", "withdrawn"]
    reason: str = Field(min_length=1, max_length=500)


class Offering(Strict):
    course_code: str
    term_code: str
    branch: str
    semester: int
    section: str
    id: UUID
    course_id: UUID
    term_id: UUID
    class_group_id: UUID
    title: str
    status: str
    roster_version: int
    version: int


class SessionWork(Strict):
    id: UUID
    status: str
    starts_at: datetime


class OfferingWork(Offering):
    join_requests: int
    face_reviews: int
    open_queries: int
    sessions: list[SessionWork]


class TeacherWorkSummary(Strict):
    items: list[OfferingWork]
    truncated: bool


class Enrollment(Strict):
    id: UUID
    offering_id: UUID
    student_id: UUID
    status: str
    version: int


class Code(Strict):
    id: UUID
    offering_id: UUID
    code: str
    expires_at: datetime
    version: int


T = TypeVar("T")


class Page(Strict, Generic[T]):
    items: list[T]
    next_cursor: UUID | None


class ClaimResult(Strict):
    student_id: UUID
    institute_id: UUID
    status: Literal["linked"]


class Membership(Strict):
    id: UUID
    institute_id: UUID
    institute_name: str
    role: str
    status: str


class StudentProfile(Strict):
    id: UUID
    institute_id: UUID
    enrollment_number: str
    official_name: str
    status: str


class TeacherProfile(Strict):
    id: UUID
    institute_id: UUID
    employee_number: str
    official_name: str
    status: str


class Me(Strict):
    user_id: UUID
    memberships: list[Membership]
    students: list[StudentProfile]
    teachers: list[TeacherProfile]


class Course(Strict):
    id: UUID
    code: str
    title: str
    status: str
    version: int


class Term(Strict):
    id: UUID
    code: str
    starts_on: date
    ends_on: date
    version: int


DEFAULT_GROUP_SECTION = "ALL"


class ClassGroup(Strict):
    id: UUID
    term_id: UUID
    branch: str
    semester: int
    section: str
    version: int


class RosterEntry(Enrollment):
    enrollment_number: str
    official_name: str


class ErrorDetail(Strict):
    loc: list[str | int]
    type: str


class Error(Strict):
    code: str
    message: str
    request_id: str
    retryable: bool
    details: list[ErrorDetail]


class ErrorEnvelope(Strict):
    error: Error


class OwnEnrollment(Enrollment):
    offering: Offering
    reason: str | None = None
