import java.io.File;
import java.util.*;

public class PhotonLauncher {
    public static void main(String[] args) throws Exception {
        File photonDir = new File("/photon");
        if (!photonDir.exists()) {
            System.err.println("❌ Error: Directory /photon does not exist");
            System.exit(1);
        }
        if (!photonDir.canWrite()) {
            System.err.println("❌ Error: No write permission to /photon");
            System.exit(1);
        }

        List<String> command = new ArrayList<>();
        command.add("java");
        command.add("-jar");
        command.add("/app/photon.jar");
        command.add("-data-dir");
        command.add("/photon");

        if (args.length > 0 && args[0] != null && args[0].trim().equalsIgnoreCase("import")) {
            System.out.println("🔄 Importing from Nominatim...");
            command.add("-nominatim-import");
            command.add("-host");
            command.add(System.getenv("DB_HOST"));
            command.add("-port");
            command.add(System.getenv("DB_PORT"));
            command.add("-database");
            command.add(System.getenv("DB_NAME"));
            command.add("-user");
            command.add(System.getenv("DB_USER"));
            command.add("-password");
            command.add(System.getenv("DB_PASSWORD"));
            command.add("-languages");
            command.add(System.getenv("PHOTON_LANGUAGES"));
        } else {
            System.out.println("🚀 Starting Photon in server mode...");
        }

        System.out.println("👉 Running command:");
        for (String part : command) {
            System.out.print(part + " ");
        }
        System.out.println();

        new ProcessBuilder(command)
            .inheritIO()
            .start()
            .waitFor();
    }
}
