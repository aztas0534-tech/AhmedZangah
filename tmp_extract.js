import fs from 'fs';

const src = 'c:\\nasrflash\\AhmedZ\\supabase\\migrations\\20260227025200_fix_returns_party_currency_uom.sql';
const dest = 'c:\\nasrflash\\AhmedZ\\supabase\\migrations\\20260228054000_restore_post_inventory_movement_full.sql';

const lines = fs.readFileSync(src, 'utf-8').split('\n');
let extracted = lines.slice(474, 762).join('\n'); // Up to 761 inclusive

extracted += '\n\nnotify pgrst, \'reload schema\';\n';

fs.writeFileSync(dest, extracted, 'utf-8');
console.log('Created ' + dest);
