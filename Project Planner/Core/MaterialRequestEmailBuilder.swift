//
//  MaterialRequestEmailBuilder.swift
//  Project Planner
//
//  HTML templates aligned with material-order.html / material-quote.html (Downloads).
//

import Foundation

enum MaterialRequestEmailBuilder {

    struct Context {
        let supplierName: String
        let userName: String
        let userEmail: String
        let userPhone: String?
        let userCompany: String
        let jobNumber: String
        let siteName: String?
        let deliveryAddress: String?
        let requestedDate: String?
        let quoteNeededBy: String?
        let companyLogoURL: String?
        let materials: [MaterialItem]
        let sentAt: Date
    }

    static func buildQuoteEmail(context: Context) -> String {
        renderTemplate(quoteTemplate, context: context, isQuote: true)
    }

    static func buildOrderEmail(context: Context) -> String {
        renderTemplate(orderTemplate, context: context, isQuote: false)
    }

    static func quoteSubject(jobNumber: String, company: String) -> String {
        "Quote request — \(jobNumber) — \(company)"
    }

    static func orderSubject(jobNumber: String, company: String) -> String {
        "Material order request — \(jobNumber) — \(company)"
    }

    // MARK: - Rendering

    private static func renderTemplate(_ template: String, context: Context, isQuote: Bool) -> String {
        let supplier = context.supplierName.trimmingCharacters(in: .whitespacesAndNewlines)
        let supplierGreeting = supplier.isEmpty ? "there" : supplier
        let itemCount = context.materials.count
        let itemCountLabel = itemCount == 1 ? "item" : "items"
        let sentDate = formattedSentDate(context.sentAt)
        let siteName = context.siteName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let siteSuffix = siteName.isEmpty ? "" : " · <span style=\"font-weight:600;color:#475569;\">\(escapeHTML(siteName))</span>"
        let jobPanelValue = "\(escapeHTML(context.jobNumber))\(siteSuffix)"
        let companyLogoBlock = companyLogoHeaderHTML(url: context.companyLogoURL)
        let jobHeaderPill = isQuote
            ? "Job (\(escapeHTML(context.jobNumber)))"
            : "JOB · \(escapeHTML(context.jobNumber))"
        let introFollowUp = isQuote
            ? quoteIntroFollowUp(phone: context.userPhone)
            : orderIntroFollowUp(phone: context.userPhone)
        let signOffLine = isQuote
            ? "Thank you for taking the time to quote these materials."
            : "Thank you for processing this order."
        let itemsHTML = itemsTableHTML(materials: context.materials, qtyBadgeStyle: isQuote ? "quote" : "order")
        let optionalDateRow = optionalPanelDateRow(isQuote: isQuote, context: context)
        let contactPhoneBlock = contactPhoneHTML(phone: context.userPhone)
        let preheader = isQuote
            ? "Quote request from \(escapeHTML(context.userName)) (\(escapeHTML(context.userCompany))) for job \(escapeHTML(context.jobNumber)) — pricing & lead time please."
            : "Order request from \(escapeHTML(context.userName)) (\(escapeHTML(context.userCompany))) for job \(escapeHTML(context.jobNumber)) — please confirm availability and delivery."

        var html = template
        html = html.replacingOccurrences(of: "{{PREHEADER}}", with: preheader)
        html = html.replacingOccurrences(of: "{{JOB_HEADER_PILL}}", with: jobHeaderPill)
        html = html.replacingOccurrences(of: "{{COMPANY_LOGO_HEADER}}", with: companyLogoBlock)
        html = html.replacingOccurrences(of: "{{SUPPLIER_NAME}}", with: escapeHTML(supplierGreeting))
        html = html.replacingOccurrences(of: "{{INTRO_FOLLOW_UP}}", with: introFollowUp)
        html = html.replacingOccurrences(of: "{{JOB_PANEL_VALUE}}", with: jobPanelValue)
        html = html.replacingOccurrences(of: "{{USER_COMPANY}}", with: escapeHTML(context.userCompany))
        html = html.replacingOccurrences(of: "{{OPTIONAL_DATE_ROW}}", with: optionalDateRow)
        html = html.replacingOccurrences(of: "{{ITEM_COUNT}}", with: "\(itemCount)")
        html = html.replacingOccurrences(of: "{{ITEM_COUNT_LABEL}}", with: itemCountLabel)
        html = html.replacingOccurrences(of: "{{ITEMS_TABLE_ROWS}}", with: itemsHTML)
        html = html.replacingOccurrences(of: "{{SIGN_OFF_LINE}}", with: signOffLine)
        html = html.replacingOccurrences(of: "{{USER_NAME}}", with: escapeHTML(context.userName))
        html = html.replacingOccurrences(of: "{{CONTACT_PHONE_BLOCK}}", with: contactPhoneBlock)
        html = html.replacingOccurrences(of: "{{USER_EMAIL}}", with: escapeHTML(context.userEmail))
        html = html.replacingOccurrences(of: "{{SENT_DATE}}", with: escapeHTML(sentDate))
        if isQuote {
            html = html.replacingOccurrences(of: "{{DELIVER_TO_CELL}}", with: deliverToCellHTML(address: context.deliveryAddress))
        } else {
            html = html.replacingOccurrences(of: "{{DELIVERY_ADDRESS}}", with: escapeHTML(context.deliveryAddress ?? ""))
        }
        return html
    }

    private static func quoteIntroFollowUp(phone: String?) -> String {
        let trimmed = phone?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            return "Once the quote is ready, please can you confirm lead times. Please note, this is only a quote request."
        }
        let tel = trimmed.replacingOccurrences(of: " ", with: "")
        return "Once the quote is ready, please can you confirm lead times. Please note, this is only a quote request. <a href=\"tel:\(escapeHTML(tel))\" style=\"color:#0ea5e9;text-decoration:none;font-weight:600;\">\(escapeHTML(trimmed))</a>"
    }

    private static func orderIntroFollowUp(phone: String?) -> String {
        let trimmed = phone?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            return "Please confirm any long lead times before processing this order."
        }
        let tel = trimmed.replacingOccurrences(of: " ", with: "")
        return "Please confirm any long lead times before processing this order — <a href=\"tel:\(escapeHTML(tel))\" style=\"color:#0ea5e9;text-decoration:none;font-weight:600;\">\(escapeHTML(trimmed))</a>"
    }

    private static func contactPhoneHTML(phone: String?) -> String {
        let trimmed = phone?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "" }
        let tel = trimmed.replacingOccurrences(of: " ", with: "")
        return """
        <td style="font-size:13.5px;color:#475569;padding-right:14px;">
          <a href="tel:\(escapeHTML(tel))" style="color:#0b1220;text-decoration:none;font-weight:600;">📞&nbsp;\(escapeHTML(trimmed))</a>
        </td>
        """
    }

    private static func companyLogoHeaderHTML(url: String?) -> String {
        let trimmed = url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, let _ = URL(string: trimmed) else {
            return ""
        }
        return """
        <td align="right" style="vertical-align:middle;width:120px;">
          <img src="\(escapeHTML(trimmed))" alt="Company logo" width="96" height="40" style="display:block;max-width:96px;max-height:40px;width:auto;height:auto;margin-left:auto;border:0;outline:none;" />
        </td>
        """
    }

    private static func deliverToCellHTML(address: String?) -> String {
        let addr = address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !addr.isEmpty else { return "" }
        return """
        <td class="stack stack-pad" width="50%" style="padding:16px 18px;vertical-align:top;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;">
          <div style="font-size:11px;font-weight:700;letter-spacing:.08em;color:#7c8aa0;text-transform:uppercase;">Deliver to</div>
          <div style="font-size:14px;color:#0b1220;margin-top:4px;line-height:20px;font-weight:600;">\(escapeHTML(addr))</div>
        </td>
        """
    }

    private static func optionalPanelDateRow(isQuote: Bool, context: Context) -> String {
        if isQuote {
            let needed = context.quoteNeededBy?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !needed.isEmpty else { return "" }
            return """
            <tr><td colspan="2" style="border-top:1px solid #e3e8ef;padding:12px 18px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;">
              <span style="display:inline-block;font-size:11px;font-weight:700;letter-spacing:.08em;color:#7c8aa0;text-transform:uppercase;">Quote needed by:&nbsp;</span>
              <span style="font-size:14px;font-weight:700;color:#0b1220;">\(escapeHTML(needed))</span>
            </td></tr>
            """
        }
        let requested = context.requestedDate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !requested.isEmpty else { return "" }
        return """
        <tr><td colspan="2" style="border-top:1px solid #e3e8ef;padding:12px 18px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;">
          <span style="display:inline-block;font-size:11px;font-weight:700;letter-spacing:.08em;color:#7c8aa0;text-transform:uppercase;">Requested date:&nbsp;</span>
          <span style="font-size:14px;font-weight:700;color:#0b1220;">\(escapeHTML(requested))</span>
        </td></tr>
        """
    }

    private static func itemsTableHTML(materials: [MaterialItem], qtyBadgeStyle: String) -> String {
        let badgeColors: (bg: String, fg: String) = qtyBadgeStyle == "quote"
            ? ("#e1f5ee", "#0f6e56")
            : ("#e6f0fc", "#185fa5")
        return materials.map { material in
            let name = escapeHTML(material.material)
            let manufacturer = escapeHTML(material.brand?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? material.brand!
                : "—")
            let part = material.productCode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let partHTML = part.isEmpty ? "" : " · Part: <span style=\"color:#475569;font-weight:600;\">\(escapeHTML(part))</span>"
            let lengthSpec = material.formattedLengthSpecification
            let lengthHTML = lengthSpec.isEmpty ? "" : " · Length: <span style=\"color:#475569;font-weight:600;\">\(escapeHTML(lengthSpec))</span>"
            let notes = material.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let notesHTML = notes.isEmpty ? "" : "<div style=\"font-size:12.5px;color:#7c8aa0;margin-top:3px;line-height:18px;font-style:italic;\">\(escapeHTML(notes))</div>"
            let qtyLabel = escapeHTML(material.unit.quantityLabel(for: material.quantity))
            return """
            <tr><td style="padding:14px 16px;border-bottom:1px solid #eef1f6;background:#ffffff;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;">
              <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">
                <tr>
                  <td style="vertical-align:top;">
                    <div style="font-size:15px;font-weight:700;color:#0b1220;line-height:20px;">\(name)</div>
                    <div style="font-size:12.5px;color:#7c8aa0;margin-top:3px;line-height:18px;">
                      Manufacturer: <span style="color:#475569;font-weight:600;">\(manufacturer)</span>\(partHTML)\(lengthHTML)
                    </div>
                    \(notesHTML)
                  </td>
                  <td align="right" style="vertical-align:top;padding-left:14px;white-space:nowrap;">
                    <span style="display:inline-block;background:\(badgeColors.bg);color:\(badgeColors.fg);font-size:13px;font-weight:800;padding:6px 12px;border-radius:999px;">\(material.quantity) \(qtyLabel)</span>
                  </td>
                </tr>
              </table>
            </td></tr>
            """
        }.joined()
    }

    private static func formattedSentDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "EEEE, d MMMM yyyy 'at' HH:mm"
        return formatter.string(from: date)
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let quoteTemplate = quoteTemplateHTML
    private static let orderTemplate = orderTemplateHTML
}

// MARK: - Embedded templates (from Downloads HTML, with product copy updates)

private let quoteTemplateHTML = """
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" lang="en">
<head>
<meta http-equiv="Content-Type" content="text/html; charset=UTF-8" />
<meta name="viewport" content="width=device-width,initial-scale=1" />
<meta name="x-apple-disable-message-reformatting" />
<meta http-equiv="X-UA-Compatible" content="IE=edge" />
<title>Quote request</title>
<style type="text/css">
  body,table,td,a{-webkit-text-size-adjust:100%;-ms-text-size-adjust:100%;}
  table,td{mso-table-lspace:0pt;mso-table-rspace:0pt;border-collapse:collapse;}
  img{-ms-interpolation-mode:bicubic;border:0;outline:none;text-decoration:none;display:block;}
  body{margin:0;padding:0;width:100%!important;background:#eef2f7;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;}
  a{color:#0ea5e9;text-decoration:none;}
  @media (prefers-color-scheme: dark) { .bg-page{background:#0b1220!important;} }
  @media only screen and (max-width:620px) {
    .container{width:100%!important;}
    .px{padding-left:22px!important;padding-right:22px!important;}
    .stack{display:block!important;width:100%!important;}
    .stack-pad{padding:10px 0 0 0!important;}
    .h1{font-size:24px!important;line-height:30px!important;}
  }
</style>
</head>
<body class="bg-page" style="margin:0;padding:0;background:#eef2f7;">
<div style="display:none;font-size:1px;color:#eef2f7;line-height:1px;max-height:0;max-width:0;opacity:0;overflow:hidden;">
  {{PREHEADER}}
</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#eef2f7;">
  <tr><td align="center" style="padding:24px 12px;">
    <table role="presentation" class="container" width="600" cellpadding="0" cellspacing="0" border="0" style="width:600px;max-width:600px;background:#ffffff;border-radius:14px;overflow:hidden;box-shadow:0 1px 2px rgba(11,18,32,.04),0 8px 28px rgba(11,18,32,.06);">
      <tr><td style="background:#0b1220;padding:22px 32px;">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">
          <tr>
            <td align="left" style="vertical-align:middle;">
              <span style="display:inline-block;background:#0ea5e9;color:#ffffff;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-size:11px;font-weight:800;letter-spacing:.08em;padding:6px 12px;border-radius:999px;">{{JOB_HEADER_PILL}}</span>
            </td>
            {{COMPANY_LOGO_HEADER}}
          </tr>
          <tr><td colspan="2" style="padding-top:14px;">
            <table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>
              <td style="vertical-align:middle;padding-right:11px;">
                <svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 32 32" role="img" aria-label="Project Planner">
                  <rect x="4" y="14" width="5" height="14" rx="1.3" fill="#0ea5e9"/>
                  <rect x="11" y="9" width="5" height="19" rx="1.3" fill="#2563eb"/>
                  <rect x="18" y="5" width="5" height="23" rx="1.3" fill="#60a5fa"/>
                  <rect x="25" y="11" width="5" height="17" rx="1.3" fill="#0ea5e9"/>
                </svg>
              </td>
              <td style="vertical-align:middle;">
                <div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-size:15px;font-weight:800;letter-spacing:.06em;color:#ffffff;line-height:1;">
                  PROJECT <span style="color:#0ea5e9;">PLANNER</span>
                </div>
                <div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-size:11px;color:#9fb0c9;margin-top:4px;letter-spacing:.04em;">
                  Material quote request
                </div>
              </td>
            </tr></table>
          </td></tr>
        </table>
      </td></tr>
      <tr><td class="px" style="padding:30px 32px 8px 32px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;">
        <p style="margin:0 0 6px 0;font-size:15px;color:#475569;">Hi {{SUPPLIER_NAME}},</p>
        <h1 class="h1" style="margin:6px 0 12px 0;font-size:26px;line-height:32px;font-weight:800;color:#0b1220;letter-spacing:-.01em;">Can I get a quote for the items below?</h1>
        <p style="margin:0;font-size:15px;line-height:22px;color:#475569;">{{INTRO_FOLLOW_UP}}</p>
      </td></tr>
      <tr><td class="px" style="padding:22px 32px 6px 32px;">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#f5f8fc;border:1px solid #e3e8ef;border-radius:12px;">
          <tr>
            <td class="stack" width="50%" style="padding:16px 18px;vertical-align:top;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;border-right:1px solid #e3e8ef;">
              <div style="font-size:11px;font-weight:700;letter-spacing:.08em;color:#7c8aa0;text-transform:uppercase;">Job name and reference</div>
              <div style="font-size:17px;font-weight:800;color:#0b1220;margin-top:4px;">{{JOB_PANEL_VALUE}}</div>
            </td>
            <td class="stack stack-pad" width="50%" style="padding:16px 18px;vertical-align:top;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;">
              <div style="font-size:11px;font-weight:700;letter-spacing:.08em;color:#7c8aa0;text-transform:uppercase;">Company</div>
              <div style="font-size:14px;color:#0b1220;margin-top:4px;line-height:20px;font-weight:700;">{{USER_COMPANY}}</div>
            </td>
          </tr>
          {{OPTIONAL_DATE_ROW}}
        </table>
      </td></tr>
      <tr><td class="px" style="padding:22px 32px 10px 32px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"><tr>
          <td align="left" style="font-size:12px;font-weight:700;letter-spacing:.08em;color:#0ea5e9;text-transform:uppercase;">Items to price</td>
          <td align="right" style="font-size:12px;color:#7c8aa0;font-weight:600;">{{ITEM_COUNT}} {{ITEM_COUNT_LABEL}}</td>
        </tr></table>
      </td></tr>
      <tr><td class="px" style="padding:0 32px 6px 32px;">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border:1px solid #e3e8ef;border-radius:12px;overflow:hidden;">
          <tr><td style="background:#0b1220;padding:11px 16px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;">
            <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"><tr>
              <td style="font-size:11px;font-weight:700;letter-spacing:.08em;color:#ffffff;text-transform:uppercase;">Item</td>
              <td align="right" style="font-size:11px;font-weight:700;letter-spacing:.08em;color:#ffffff;text-transform:uppercase;">Qty</td>
            </tr></table>
          </td></tr>
          {{ITEMS_TABLE_ROWS}}
        </table>
      </td></tr>
      <tr><td class="px" style="padding:28px 32px 10px 32px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;">
        <p style="margin:0 0 18px 0;font-size:15px;color:#475569;line-height:22px;">{{SIGN_OFF_LINE}}</p>
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#f5f8fc;border:1px solid #e3e8ef;border-radius:12px;">
          <tr><td style="padding:18px 20px;">
            <div style="font-size:11px;font-weight:700;letter-spacing:.08em;color:#7c8aa0;text-transform:uppercase;margin-bottom:8px;">Kind regards</div>
            <div style="font-size:17px;font-weight:800;color:#0b1220;line-height:22px;">{{USER_NAME}}</div>
            <div style="font-size:13.5px;color:#475569;margin-top:2px;line-height:20px;">{{USER_COMPANY}}</div>
            <table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin-top:10px;"><tr>
              {{CONTACT_PHONE_BLOCK}}
              <td style="font-size:13.5px;color:#475569;">
                <a href="mailto:{{USER_EMAIL}}" style="color:#0b1220;text-decoration:none;font-weight:600;">✉&nbsp;{{USER_EMAIL}}</a>
              </td>
            </tr></table>
          </td></tr>
        </table>
      </td></tr>
      <tr><td style="height:4px;background:#0ea5e9;font-size:0;line-height:0;">&nbsp;</td></tr>
      <tr><td style="background:#0b1220;padding:20px 32px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"><tr>
          <td style="font-size:11px;color:#9fb0c9;line-height:17px;">
            Sent {{SENT_DATE}} via <a href="https://projectplanner.us" style="color:#0ea5e9;text-decoration:none;font-weight:700;">Project Planner</a><br>
            <span style="color:#7c8aa0;">Replies route directly to {{USER_NAME}} at {{USER_EMAIL}}.</span>
          </td>
          <td align="right" style="vertical-align:top;">
            <svg xmlns="http://www.w3.org/2000/svg" width="22" height="22" viewBox="0 0 32 32" role="img" aria-label="Project Planner">
              <rect x="4" y="14" width="5" height="14" rx="1.3" fill="#0ea5e9"/>
              <rect x="11" y="9" width="5" height="19" rx="1.3" fill="#2563eb"/>
              <rect x="18" y="5" width="5" height="23" rx="1.3" fill="#60a5fa"/>
              <rect x="25" y="11" width="5" height="17" rx="1.3" fill="#0ea5e9"/>
            </svg>
          </td>
        </tr></table>
      </td></tr>
    </table>
    <table role="presentation" class="container" width="600" cellpadding="0" cellspacing="0" border="0" style="width:600px;max-width:600px;">
      <tr><td style="padding:16px 12px 6px 12px;text-align:center;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-size:11px;color:#7c8aa0;line-height:17px;">
        Project Planner · construction project management for site teams.<br>
        This message was generated automatically on behalf of {{USER_NAME}}.
      </td></tr>
    </table>
  </td></tr>
</table>
</body>
</html>
"""

private let orderTemplateHTML = """
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" lang="en">
<head>
<meta http-equiv="Content-Type" content="text/html; charset=UTF-8" />
<meta name="viewport" content="width=device-width,initial-scale=1" />
<meta name="x-apple-disable-message-reformatting" />
<meta http-equiv="X-UA-Compatible" content="IE=edge" />
<title>Material order request</title>
<style type="text/css">
  body,table,td,a{-webkit-text-size-adjust:100%;-ms-text-size-adjust:100%;}
  table,td{mso-table-lspace:0pt;mso-table-rspace:0pt;border-collapse:collapse;}
  img{-ms-interpolation-mode:bicubic;border:0;outline:none;text-decoration:none;display:block;}
  body{margin:0;padding:0;width:100%!important;background:#eef2f7;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;}
  a{color:#0ea5e9;text-decoration:none;}
  @media (prefers-color-scheme: dark) { .bg-page{background:#0b1220!important;} }
  @media only screen and (max-width:620px) {
    .container{width:100%!important;}
    .px{padding-left:22px!important;padding-right:22px!important;}
    .stack{display:block!important;width:100%!important;}
    .stack-pad{padding:10px 0 0 0!important;}
    .h1{font-size:24px!important;line-height:30px!important;}
  }
</style>
</head>
<body class="bg-page" style="margin:0;padding:0;background:#eef2f7;">
<div style="display:none;font-size:1px;color:#eef2f7;line-height:1px;max-height:0;max-width:0;opacity:0;overflow:hidden;">
  {{PREHEADER}}
</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#eef2f7;">
  <tr><td align="center" style="padding:24px 12px;">
    <table role="presentation" class="container" width="600" cellpadding="0" cellspacing="0" border="0" style="width:600px;max-width:600px;background:#ffffff;border-radius:14px;overflow:hidden;box-shadow:0 1px 2px rgba(11,18,32,.04),0 8px 28px rgba(11,18,32,.06);">
      <tr><td style="background:#0b1220;padding:22px 32px;">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">
          <tr>
            <td align="left" style="vertical-align:middle;">
              <span style="display:inline-block;background:#f97316;color:#ffffff;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-size:11px;font-weight:800;letter-spacing:.08em;padding:6px 12px;border-radius:999px;">{{JOB_HEADER_PILL}}</span>
            </td>
            {{COMPANY_LOGO_HEADER}}
          </tr>
          <tr><td colspan="2" style="padding-top:14px;">
            <table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>
              <td style="vertical-align:middle;padding-right:11px;">
                <svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 32 32" role="img" aria-label="Project Planner">
                  <rect x="4" y="14" width="5" height="14" rx="1.3" fill="#0ea5e9"/>
                  <rect x="11" y="9" width="5" height="19" rx="1.3" fill="#2563eb"/>
                  <rect x="18" y="5" width="5" height="23" rx="1.3" fill="#60a5fa"/>
                  <rect x="25" y="11" width="5" height="17" rx="1.3" fill="#0ea5e9"/>
                </svg>
              </td>
              <td style="vertical-align:middle;">
                <div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-size:15px;font-weight:800;letter-spacing:.06em;color:#ffffff;line-height:1;">
                  PROJECT <span style="color:#0ea5e9;">PLANNER</span>
                </div>
                <div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-size:11px;color:#9fb0c9;margin-top:4px;letter-spacing:.04em;">
                  Material order request
                </div>
              </td>
            </tr></table>
          </td></tr>
        </table>
      </td></tr>
      <tr><td class="px" style="padding:30px 32px 8px 32px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;">
        <p style="margin:0 0 6px 0;font-size:15px;color:#475569;">Hi {{SUPPLIER_NAME}},</p>
        <h1 class="h1" style="margin:6px 0 12px 0;font-size:26px;line-height:32px;font-weight:800;color:#0b1220;letter-spacing:-.01em;">Please can I place an order for the items below?</h1>
        <p style="margin:0;font-size:15px;line-height:22px;color:#475569;">{{INTRO_FOLLOW_UP}}</p>
      </td></tr>
      <tr><td class="px" style="padding:22px 32px 6px 32px;">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#f5f8fc;border:1px solid #e3e8ef;border-radius:12px;">
          <tr>
            <td class="stack" width="50%" style="padding:16px 18px;vertical-align:top;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;border-right:1px solid #e3e8ef;">
              <div style="font-size:11px;font-weight:700;letter-spacing:.08em;color:#7c8aa0;text-transform:uppercase;">Job name and reference</div>
              <div style="font-size:17px;font-weight:800;color:#0b1220;margin-top:4px;">{{JOB_PANEL_VALUE}}</div>
            </td>
            <td class="stack stack-pad" width="50%" style="padding:16px 18px;vertical-align:top;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;">
              <div style="font-size:11px;font-weight:700;letter-spacing:.08em;color:#7c8aa0;text-transform:uppercase;">Deliver to</div>
              <div style="font-size:14px;color:#0b1220;margin-top:4px;line-height:20px;font-weight:600;">{{DELIVERY_ADDRESS}}</div>
            </td>
          </tr>
          {{OPTIONAL_DATE_ROW}}
        </table>
      </td></tr>
      <tr><td class="px" style="padding:22px 32px 10px 32px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"><tr>
          <td align="left" style="font-size:12px;font-weight:700;letter-spacing:.08em;color:#0ea5e9;text-transform:uppercase;">Materials requested</td>
          <td align="right" style="font-size:12px;color:#7c8aa0;font-weight:600;">{{ITEM_COUNT}} {{ITEM_COUNT_LABEL}}</td>
        </tr></table>
      </td></tr>
      <tr><td class="px" style="padding:0 32px 6px 32px;">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border:1px solid #e3e8ef;border-radius:12px;overflow:hidden;">
          <tr><td style="background:#0b1220;padding:11px 16px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;">
            <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"><tr>
              <td style="font-size:11px;font-weight:700;letter-spacing:.08em;color:#ffffff;text-transform:uppercase;">Item</td>
              <td align="right" style="font-size:11px;font-weight:700;letter-spacing:.08em;color:#ffffff;text-transform:uppercase;">Qty</td>
            </tr></table>
          </td></tr>
          {{ITEMS_TABLE_ROWS}}
        </table>
      </td></tr>
      <tr><td class="px" style="padding:28px 32px 10px 32px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;">
        <p style="margin:0 0 18px 0;font-size:15px;color:#475569;line-height:22px;">{{SIGN_OFF_LINE}}</p>
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#f5f8fc;border:1px solid #e3e8ef;border-radius:12px;">
          <tr><td style="padding:18px 20px;">
            <div style="font-size:11px;font-weight:700;letter-spacing:.08em;color:#7c8aa0;text-transform:uppercase;margin-bottom:8px;">Kind regards</div>
            <div style="font-size:17px;font-weight:800;color:#0b1220;line-height:22px;">{{USER_NAME}}</div>
            <div style="font-size:13.5px;color:#475569;margin-top:2px;line-height:20px;">{{USER_COMPANY}}</div>
            <table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin-top:10px;"><tr>
              {{CONTACT_PHONE_BLOCK}}
              <td style="font-size:13.5px;color:#475569;">
                <a href="mailto:{{USER_EMAIL}}" style="color:#0b1220;text-decoration:none;font-weight:600;">✉&nbsp;{{USER_EMAIL}}</a>
              </td>
            </tr></table>
          </td></tr>
        </table>
      </td></tr>
      <tr><td style="height:4px;background:#0ea5e9;font-size:0;line-height:0;">&nbsp;</td></tr>
      <tr><td style="background:#0b1220;padding:20px 32px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"><tr>
          <td style="font-size:11px;color:#9fb0c9;line-height:17px;">
            Sent {{SENT_DATE}} via <a href="https://projectplanner.us" style="color:#0ea5e9;text-decoration:none;font-weight:700;">Project Planner</a><br>
            <span style="color:#7c8aa0;">Replies route directly to {{USER_NAME}} at {{USER_EMAIL}}.</span>
          </td>
          <td align="right" style="vertical-align:top;">
            <svg xmlns="http://www.w3.org/2000/svg" width="22" height="22" viewBox="0 0 32 32" role="img" aria-label="Project Planner">
              <rect x="4" y="14" width="5" height="14" rx="1.3" fill="#0ea5e9"/>
              <rect x="11" y="9" width="5" height="19" rx="1.3" fill="#2563eb"/>
              <rect x="18" y="5" width="5" height="23" rx="1.3" fill="#60a5fa"/>
              <rect x="25" y="11" width="5" height="17" rx="1.3" fill="#0ea5e9"/>
            </svg>
          </td>
        </tr></table>
      </td></tr>
    </table>
    <table role="presentation" class="container" width="600" cellpadding="0" cellspacing="0" border="0" style="width:600px;max-width:600px;">
      <tr><td style="padding:16px 12px 6px 12px;text-align:center;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-size:11px;color:#7c8aa0;line-height:17px;">
        Project Planner · construction project management for site teams.<br>
        This message was generated automatically on behalf of {{USER_NAME}}.
      </td></tr>
    </table>
  </td></tr>
</table>
</body>
</html>
"""
