select pronargs, proargnames, prosrc 
from pg_proc 
where proname = 'deduct_stock_on_delivery_v2';
