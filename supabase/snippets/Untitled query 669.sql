select routine_name
from information_schema.routines
where routine_schema = 'public'
and routine_name like '%fx%';
