# 📍 MapOps

**MapOps** es un entorno de servicios geoespaciales listo para producción. Incluye los siguientes componentes:

-   **Nominatim** – Servicio de geocodificación directo e inverso.
-   **Photon** – Motor de búsqueda basado en Nominatim.
-   **OpenRouteService (ORS)** – Servicio de rutas y navegación.
    
Este repositorio contiene todo lo necesario para importar, inicializar y poner en marcha estos servicios utilizando archivos `.osm.pbf`. Además, se asume que el mapa cargado en ORS será el mismo utilizado por Nominatim y Photon, para mantener la coherencia espacial entre los servicios.

Los únicos requisitos que necesita para poner este proyecto en marcha son docker y docker compose para la gestión de los contenedores.

---
## 🗺️ 1. Cargar un mapa
Todos los servicios requieren un mapa para funcionar: ORS para gestionar la ruta entre dos coordenadas y Nominatim/Photon las etiquetas. El primer paso es descargar un mapa en formato `.osm.pbf` (OpenStreetMap Protocolbuffer).

Tiene disponible muchos mapas en [GeoFabrik](https://www.geofabrik.de/data/download.html), ya sea de pequeñas regiones, países o continentes. También puede confeccionar un mapa personalizado recortando una parte de un mapa mayor (por ejemplo dos provincias o regiones) gracias a [BBBike](https://extract.bbbike.org/) . En cualquier caso, cuando tenga el mapa en formato osm.pbf deberá colocarlo en `ors/files/mi_mapa.osm.pbf` . Tenga en cuenta el nombre con el que designa el mapa, ya que lo necesitará para la configuración.

Adicionalmente, si se plantea usarlo en Nominatim/Photon, deberá copiarlo a la carpeta `importer/maps/map.osm.pbf` 
> **Importante:** El nombre del archivo dentro de `importer/maps/` debe ser exactamente `map.osm.pbf`.

## 🚀 ORS. Servicio para el cálculo de rutas

Diríjase a `ors/config/`. Allí encontrará archivos de ejemplo para la configuración de ORS: el fichero más extenso posible, el fichero mínimo viable, etc. Recomendamos el uso del fichero mínimo e ir construyendo su propia configuración desde allí. En cualquier caso, deberá definir un fichero `ors-config.yml`. 
> Recuerde el nombre que le puso a su mapa: tendrá que configurarlo en este fichero.

Hecho esto, arranque el contenedor. Le recomendamos que lo arranque en modo "background" para que cuando finalice el proceso, el contenedor siga arrancado. Puede seguir el proceso mediante la visualización de logs con `docker logs`.

```sh
docker compose up -d ors
docker logs -f ors
```

Durante el primer arranque, se realizará la importación inicial de datos. Este proceso puede tardar varios minutos para un mapa regional e incluso horas si es un mapa de un país extenso o continentes.

Cuando el proceso de importación haya finalizado, estará listo para recibir peticiones. Puede verificarlo con una petición como la siguiente (tenga en cuenta las coordenadas de su mapa y el puerto en el que configuró ORS):

```sh
curl -X POST \ "http://localhost:8082/ors/v2/directions/driving-car" \
  -H "Content-Type: application/json" \
  -d '{
    "coordinates": [
      [-5.512451, 40.352344],
      [-4.683147, 40.647345]
    ],
    "instructions": true,
    "language": "es",
    "units": "km"
  }'
  ```

## 🌍 Geocodificación: Nominatim y Photon
Estos servicios permiten determinar las coordenadas de un punto de su mapa a través de un nombre o dirección (geocoding) y viceversa, encontrar el nombre y dirección de unas coordenadas dadas (geocoding inverso). 

Nominatim es un estándar "de-facto" y está mantenido por el equipo de OpenStreetMap. Tiene una precisión muy alta y está muy bien estructurado. Sin embargo, requiere más capacidad de cómputo y no permite hacer autocompletado (ir mostrando al usuario direcciones a medida que escribe en un input).

Para paliar estos problemas está Photon: es menos preciso que Nominatim pero, al usar Elasticsearch, es tremendamente rápido y permite ir autocompletando al usuario. Sin embargo, para poner en marcha Photon, este requiere importar los datos de una base de datos Postgres que usa Nominatim y que mantiene ya estructurada.

Un sistema completo podría ir completando con Photon y, cuando el usuario haya terminado de escribir, recurrir a Nominatim. Este proyecto incluye los dos; luego podrá elegir con cual se queda: uno de ellos o los dos.

### 1. Importación de datos en Nominatim
Tanto si quiere usar Photon como si quiere usar Nominatim, el primer paso es crear la base de datos Postgres de Nominatim. Para ello, usaremos el docker-compose.import.yml. Este contiene los contenedores efímeros que solo usaremos durante el proceso de importación de datos.

El primer paso es cargar los datos en Nominatim. Asegúrese de que existe el mapa en el directorio `importer/maps/map.osm.pbf`. Hecho esto, arranque el proceso de importación:
```
docker compose -f docker-compose.import.yml up -d nominatim-importer
docker logs -f nominatim-importer
``` 
> Recomendado arrancar el contenedor de nominatim-importer en modo deattach (background) para que cuando acabe la importación, el servidor siga funcionando y permita a Photon conectarse. Puede ver los logs con la herramienta de logs de docker.

Espere hasta ver el siguiente mensaje en los logs:
```
[INFO] Starting gunicorn ...
[INFO] Listening at: http://0.0.0.0:8080 ...
``` 
Esto significa que el proceso de creación y volcado de datos ha finalizado correctamente. Podemos pasar a la importación de datos a Photon. Si no quieres usarlo, puedes saltarte el siguiente paso.

### 2. Importación de datos en Photon

>Este paso depende de que Nominatim ya haya completado su proceso de importación, así que asegúrese de haber completado la importación anterior.

En el docker-compose.import.yml viene definido el Dockerfile de Photon, ya que tendremos que crear la imagen nosotros mismos (photon no tiene imagen de docker oficial), pero es un proceso automático. La imagen únicamente descarga los datos de Github e incorpora `wget` como herramienta auxiliar para realizar comprobaciones de salud del servicio. Construyamos la imagen e importemos los datos de Nominatim:

```
docker compose -f docker-compose.import.yml up nominatim-importer
```
> No use la opción "-d" de up. El contenedor se cerrará automáticamente cuando complete la operación


La importación comienza cuando vea `[main] INFO de.komoot.photon.nominatim.NominatimConnector - Start importing documents...` . Una vez finalizado, el contenedor se cerrará automáticamente.

Llegados a este punto, Nominatim y Photon ya tiene los datos que necesitan para funcionar en producción, así que pasemos a esa fase.

### 3. Nominatim y Photon en producción
Tras completar las importaciones de ambos sistemas, ya estamos en condición de arrancar los contenedores de producción. 

`docker compose up -d nominatim photon` 

Puede verificar que todo está funcionando mediante la herramienta de logs de docker. Espere unos segundos y haga las siguientes peticiones vía cUrl para verificar que los servicios están respondiendo.

```sh
curl "http://localhost:8080/search?q=Madrid&format=json"  # Nominatim 
curl "http://localhost:2322/api?q=Gran+Vía"  # Photon
```
> Tenga en cuenta la cobertura de su mapa y use direcciones o coordenadas que estén incluidas en su mapa. También tenga en cuenta si cambió los puertos de los contenedores

### 4. Limpieza de importadores y recursos temporales

Llegados a este punto, los contenedores de producción de Nominatim y de Photon están funcionando, por lo que podemos eliminar los contenedores que hemos usado para cargar los datos. También podemos borrar el mapa que usamos para estos dos contenedores. Podemos eliminarlos, ya que no son necesarios para la ejecución de los servicios en producción.

```sh
docker stop nominatim-importer 
docker rm nominatim-importer
docker stop photon-importer
docker rm photon-importer

rm importer/maps/map.osm.pbf
```

**(Opcional)**: puede eliminar los datos de Nominatim si no piensa utilizar este servicio (y solo los cargó para que Photon funcionase). En ese caso, y solo en ese caso, podemos borrar los contenedores de Nominatim, los datos generados y la imagen de docker:

```
docker stop nominatim
docker rm nominatim
docker rmi mediagis/nominatim 
rm -rf nominatim-data
```

## 🤝 Contribución

Si desea colaborar con este proyecto, abra un *pull request* o cree un *issue* para sugerencias, mejoras o reportes de errores.

## 📄 Licencia

Este proyecto se distribuye bajo los términos de la licencia **GNU General Public License v3.0 (GPLv3)**.

Esto implica que:

- Puede usar, modificar y redistribuir este software libremente.
- Cualquier modificación o redistribución debe mantenerse también bajo licencia GPLv3.
- Debe incluir siempre el texto de la licencia original.

MapOps incluye componentes licenciados bajo GPLv3 (como Nominatim y OpenRouteService), por lo que esta licencia aplica a todo el conjunto del proyecto.

Para más detalles, consulte el archivo [LICENSE](./LICENSE) o visite [gnu.org/licenses/gpl-3.0](https://www.gnu.org/licenses/gpl-3.0.html).
