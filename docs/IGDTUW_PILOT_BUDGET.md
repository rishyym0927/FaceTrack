# FaceTrack hosting budget for 100 IGDTUW students

**Funding request: ₹40,000 for a five-month pilot.** The planned hosting cost is about ₹33,100. The remaining ₹6,900 is a reserve for taxes, exchange-rate changes and usage charges. The request works out to ₹400 per student for the full pilot. Cloud providers bill for the server and usage, with no separate per-student hosting charge in this estimate.

## Monthly breakdown

| Item | How the amount was calculated | Monthly budget | Five months |
|---|---|---:|---:|
| Azure virtual machine | ₹4.6853 per hour × 730 hours = ₹3,420.27 | ₹3,420 | ₹17,100 |
| Azure server disk and public IP | ₹502.81 for a 64 GiB Standard SSD + ₹0.4761 per hour × 730 hours for a static IPv4 address = ₹850.36 | ₹850 | ₹4,250 |
| Supabase Pro | US$25 per month × ₹94 per US dollar, a budgeting assumption | ₹2,350 | ₹11,750 |
| College web address and HTTPS | College provides the subdomain and DNS. Caddy obtains and renews the HTTPS certificate. | ₹0 | ₹0 |
| **Base hosting** | | **₹6,620** | **₹33,100** |
| **Pilot reserve** | Held for actual charges above the base estimate | | **₹6,900** |
| **Total requested** | | | **₹40,000** |

Azure rates are Central India retail rates checked on 11 November 2026. The estimate uses a 730-hour month and assumes the service stays available around the clock. Monthly invoices vary with month length, Azure subscription terms, taxes and usage. The budget assumes no Azure for Students credit. [Azure retail rates](https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices) · [Azure disk pricing](https://azure.microsoft.com/en-in/pricing/details/managed-disks/) · [Supabase pricing](https://supabase.com/pricing) · [Caddy HTTPS](https://caddyserver.com/docs/automatic-https)

## What the Azure server pays for

The existing Azure server is a Linux `Standard_B2as_v2` in Central India with **2 virtual CPU cores and 8 GiB of memory**. Microsoft lists the AMD EPYC 7763v processor for this VM family. It is a burstable server, which means it can handle short spikes in work while it has CPU credits. It has no GPU. [Microsoft VM specifications](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/general-purpose/basv2-series)

- **The VM** serves both websites and runs the API used by both websites and Android apps. It also runs the job queue and one CPU worker that processes classroom recordings for attendance. These services share the same VM.
- **The 64 GiB SSD** holds Ubuntu, application containers, model files and temporary processing files. Azure can also bill for disk transactions. Student records and private media are stored in Supabase.
- **The static public IP** gives the college's web address a stable destination. The domain change uses the existing server and IP once college IT provides the subdomain and configures DNS.

## What Supabase pays for

Supabase provides sign-in, the PostgreSQL database for student and attendance records, and private storage for recordings. Pro includes daily database backups with seven-day retention, 8 GB of database disk, 100 GB of file storage and 250 GB of egress. Database backups cover records in PostgreSQL. The media stored as separate files requires its own backup arrangements if the college needs recoverable copies. [Supabase plan limits](https://supabase.com/pricing) · [Supabase backup scope](https://supabase.com/docs/guides/platform/backups)

## What could change the cost

- **Recording activity.** The plan assumes staggered classroom uploads and one recording job at a time. Concurrent uploads can create a queue. Measure processing time and queue length during the pilot before budgeting for another worker or a larger VM.
- **Video size and retention.** Storage rises with clip size and how long clips are kept. Downloading and processing videos uses network transfer. Track storage and transfer in the billing dashboards alongside Azure disk transactions.
- **Taxes and currency.** Apply the reserve against actual invoices and usage. The ₹94 conversion is for planning. The final rupee amount depends on the payment exchange rate and applicable taxes.

The request covers hosting for five months. Staff time, equipment, a GPU, a model licence and a separate disaster recovery setup are outside this estimate. Live biometric processing for IGDTUW requires approved model usage and a worker authorized for the institute before enrolment begins.
