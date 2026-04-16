import SwiftUI

struct CustomSecureField: View {
    let title: String
    @Binding var text: String
    @State private var isSecure: Bool = true
    
    var body: some View {
        HStack {
            if isSecure {
                TextField(title, text: $text)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .textContentType(.none)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .keyboardType(.default)
                    .submitLabel(.done)
            } else {
                TextField(title, text: $text)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .textContentType(.none)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .keyboardType(.default)
                    .submitLabel(.done)
            }
            
            Button(action: {
                isSecure.toggle()
            }) {
                Image(systemName: isSecure ? "eye.slash" : "eye")
                    .foregroundColor(.gray)
            }
        }
    }
}

#Preview {
    CustomSecureField(title: "Password", text: .constant(""))
        .padding()
}











