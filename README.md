# postgres-images
Contains custom-built PostgreSQL images to start Xata clusters 

# Local development

Install act (https://nektosact.com)

```brew install act```

Run: 
```
act -j build-test-publish \                     
-P ubuntu-latest=catthehacker/ubuntu:act-latest \
--container-architecture linux/amd64
```
