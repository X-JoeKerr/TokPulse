import Testing

@main
struct DirectTestRunner {
    static func main() async {
        await Testing.__swiftPMEntryPoint() as Never
    }
}

