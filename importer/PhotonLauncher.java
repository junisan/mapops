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

        String password = null;
        if (args.length > 0 && args[0] != null && args[0].trim().equalsIgnoreCase("import")) {
            System.out.println("🔄 Importing from Nominatim...");
            password = System.getenv("DB_PASSWORD");
            if (password == null || password.isEmpty()) {
                System.err.println("❌ Error: DB_PASSWORD is not set");
                System.exit(1);
            }
            command.add("import");
            command.add("-host");
            command.add(System.getenv("DB_HOST"));
            command.add("-port");
            command.add(System.getenv("DB_PORT"));
            command.add("-database");
            command.add(System.getenv("DB_NAME"));
            command.add("-user");
            command.add(System.getenv("DB_USER"));
            command.add("-password");
            command.add(password);
            command.add("-languages");
            command.add(System.getenv("PHOTON_LANGUAGES"));
        } else {
            System.out.println("🚀 Starting Photon in server mode...");
            command.add("serve");
            // Photon 1.x binds to 127.0.0.1 by default; inside the
            // container it must listen on all interfaces
            command.add("-listen-ip");
            command.add("0.0.0.0");
        }
        command.add("-data-dir");
        command.add("/photon");

        System.out.println("👉 Running command:");
        for (String part : command) {
            // Never print credentials
            System.out.print((password != null && part.equals(password) ? "********" : part) + " ");
        }
        System.out.println();

        int exitCode = new ProcessBuilder(command)
            .inheritIO()
            .start()
            .waitFor();
        System.exit(exitCode);
    }
}
