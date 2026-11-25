CREATE SCHEMA hostel_lab;
CREATE TABLE hostel_lab.students (
    student_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_number VARCHAR(20) UNIQUE NOT NULL,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE hostel_lab.rooms (
    room_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    room_number VARCHAR(20) UNIQUE NOT NULL,
    capacity INTEGER NOT NULL CHECK (capacity > 0)
);

CREATE TABLE hostel_lab.allocations (
    allocation_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_id INTEGER NOT NULL,
    room_id INTEGER NOT NULL,
    allocated_on DATE NOT NULL,
    released_on DATE,
    status VARCHAR(10) NOT NULL
        CHECK (status IN ('ACTIVE','ENDED')),

    CONSTRAINT fk_allocation_student
        FOREIGN KEY (student_id)
        REFERENCES hostel_lab.students(student_id),

    CONSTRAINT fk_allocation_room
        FOREIGN KEY (room_id)
        REFERENCES hostel_lab.rooms(room_id),

    CONSTRAINT chk_allocation_status
        CHECK (
            (status='ACTIVE' AND released_on IS NULL)
            OR
            (status='ENDED' AND released_on IS NOT NULL)
        )
);

CREATE TABLE hostel_lab.occupancy_snapshot (
    snapshot_date DATE NOT NULL,
    room_id INTEGER NOT NULL,
    occupied_beds INTEGER NOT NULL,
    free_beds INTEGER NOT NULL,

    PRIMARY KEY (snapshot_date, room_id),

    CONSTRAINT fk_snapshot_room
        FOREIGN KEY (room_id)
        REFERENCES hostel_lab.rooms(room_id)
);

--seed rooms
INSERT INTO hostel_lab.rooms
(room_number, capacity)
VALUES
('A101',2),
('B201',3),
('C301',2);
--seed students
INSERT INTO hostel_lab.students
(student_number, full_name)
VALUES
('20260001','John Banda'),
('20260002','Mary Phiri'),
('20260003','Peter Zulu'),
('20260004','Alice Mwale');


INSERT INTO hostel_lab.allocations
(student_id, room_id, allocated_on, released_on, status)
VALUES

(1,1,'2026-11-01',NULL,'ACTIVE'),
(2,1,'2026-11-01',NULL,'ACTIVE'),

(3,2,'2026-11-03',NULL,'ACTIVE'),

(4,2,'2026-10-01','2026-10-31','ENDED');

--B--
CREATE OR REPLACE FUNCTION
hostel_lab.fn_free_beds(
    p_room_id INTEGER
)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INTEGER;
    v_occupied INTEGER;
BEGIN

    SELECT capacity
    INTO v_capacity
    FROM hostel_lab.rooms
    WHERE room_id = p_room_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room';
    END IF;

    SELECT COUNT(*)
    INTO v_occupied
    FROM hostel_lab.allocations
    WHERE room_id = p_room_id
    AND status = 'ACTIVE';

    RETURN v_capacity - v_occupied;

END;
$$;

--C--

CREATE OR REPLACE PROCEDURE
hostel_lab.pr_allocate_room(
    p_student_id INTEGER,
    p_room_id INTEGER,
    p_allocated_on DATE
)
LANGUAGE plpgsql
AS $$
BEGIN

    IF NOT EXISTS (
        SELECT 1
        FROM hostel_lab.students
        WHERE student_id = p_student_id
    ) THEN
        RAISE EXCEPTION 'Invalid student';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM hostel_lab.rooms
        WHERE room_id = p_room_id
    ) THEN
        RAISE EXCEPTION 'Invalid room';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM hostel_lab.allocations
        WHERE student_id = p_student_id
        AND status = 'ACTIVE'
    ) THEN
        RAISE EXCEPTION
        'Student already has an active allocation';
    END IF;

    IF hostel_lab.fn_free_beds(p_room_id) <= 0 THEN
        RAISE EXCEPTION
        'Room is full';
    END IF;

    INSERT INTO hostel_lab.allocations
    (
        student_id,
        room_id,
        allocated_on,
        released_on,
        status
    )
    VALUES
    (
        p_student_id,
        p_room_id,
        p_allocated_on,
        NULL,
        'ACTIVE'
    );

END;
$$;

--D--

CREATE OR REPLACE FUNCTION
hostel_lab.fn_validate_allocation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INTEGER;
    v_active_count INTEGER;
BEGIN

    IF NEW.status = 'ACTIVE' THEN

        -- One active allocation per student

        IF EXISTS
        (
            SELECT 1
            FROM hostel_lab.allocations
            WHERE student_id = NEW.student_id
            AND status = 'ACTIVE'
            AND allocation_id <>
                COALESCE(NEW.allocation_id,-1)
        )
        THEN
            RAISE EXCEPTION
            'Student already has an active allocation';
        END IF;

        -- Capacity check

        SELECT capacity
        INTO v_capacity
        FROM hostel_lab.rooms
        WHERE room_id = NEW.room_id;

        SELECT COUNT(*)
        INTO v_active_count
        FROM hostel_lab.allocations
        WHERE room_id = NEW.room_id
        AND status = 'ACTIVE'
        AND allocation_id <>
            COALESCE(NEW.allocation_id,-1);

        IF v_active_count >= v_capacity THEN
            RAISE EXCEPTION
            'Room capacity exceeded';
        END IF;

    END IF;

    RETURN NEW;

END;
$$;

--trigger--
CREATE TRIGGER trg_validate_allocation
BEFORE INSERT OR UPDATE
ON hostel_lab.allocations
FOR EACH ROW
EXECUTE FUNCTION hostel_lab.fn_validate_allocation();

--E--

CREATE OR REPLACE VIEW
hostel_lab.v_room_occupancy AS
SELECT
    r.room_id,
    r.room_number,
    r.capacity,

    COUNT(a.allocation_id)
        FILTER (WHERE a.status='ACTIVE')
        AS occupied_beds,

    r.capacity -
    COUNT(a.allocation_id)
        FILTER (WHERE a.status='ACTIVE')
        AS free_beds

FROM hostel_lab.rooms r

LEFT JOIN hostel_lab.allocations a
ON r.room_id = a.room_id

GROUP BY
    r.room_id,
    r.room_number,
    r.capacity;
--F--
CREATE INDEX idx_active_room
ON hostel_lab.allocations
(
    room_id,
    status
);

EXPLAIN

SELECT *
FROM hostel_lab.allocations
WHERE room_id = 1
AND status = 'ACTIVE';

--G--

CREATE OR REPLACE PROCEDURE
hostel_lab.pr_refresh_occupancy()
LANGUAGE plpgsql
AS $$
BEGIN

    INSERT INTO hostel_lab.occupancy_snapshot
    (
        snapshot_date,
        room_id,
        occupied_beds,
        free_beds
    )

    SELECT
        CURRENT_DATE,
        r.room_id,

        COUNT(a.allocation_id)
            FILTER (WHERE a.status='ACTIVE'),

        r.capacity -
        COUNT(a.allocation_id)
            FILTER (WHERE a.status='ACTIVE')

    FROM hostel_lab.rooms r

    LEFT JOIN hostel_lab.allocations a
    ON r.room_id = a.room_id

    GROUP BY
        r.room_id,
        r.capacity

    ON CONFLICT
    (snapshot_date, room_id)

    DO UPDATE

    SET occupied_beds =
        EXCLUDED.occupied_beds,

        free_beds =
        EXCLUDED.free_beds;

END;
$$;

